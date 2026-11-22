# frozen_string_literal: true

require "rails_helper"
require "timeout"

RSpec.describe "Multi-night pass concurrency and lock ordering", :non_transactional, type: :request do
  self.use_transactional_tests = false

  before do
    raise "Pass concurrency tests require PostgreSQL test" unless Rails.env.test? &&
      ActiveRecord::Base.connection.adapter_name == "PostgreSQL"

    clean_data
    allow(EmailService).to receive(:send_order_confirmation_async)
    allow(Stripe::StripeClient).to receive(:new).and_raise("NO PROVIDER CLIENTS ALLOWED")
    allow(StripeService).to receive(:payment_enabled?).and_return(true)
    allow(StripeService).to receive(:create_payment_intent) do |order, **|
      OpenStruct.new(
        id: "pi_pass_lock_#{order.id}",
        client_secret: "cs_pass_lock_#{order.id}",
        allowed_payment_method_types: ["card"],
        payment_method_types: ["card"]
      )
    end
  end

  after { clean_data }

  def clean_data
    raise "Isolated test database required" unless Rails.env.test? &&
      ActiveRecord::Base.connection_db_config.database.end_with?("_test")

    ActiveRecord::Base.connection.execute(
      "TRUNCATE TABLE audit_logs, audit_write_failures, users, organizer_profiles, events, venues, site_settings, webhook_events RESTART IDENTITY CASCADE"
    )
  end

  def worker(name, outcomes, connections)
    Thread.new do
      Thread.current[:pass_worker] = name
      ActiveRecord::Base.connection_pool.with_connection do |connection|
        connection.execute("SET lock_timeout = '4s'")
        connection.execute("SET statement_timeout = '6s'")
        connections << [name, connection.select_value("SELECT pg_backend_pid()").to_i]
        begin
          outcomes << [name, yield]
        rescue StandardError => error
          outcomes << [name, error]
        ensure
          connection.execute("RESET lock_timeout")
          connection.execute("RESET statement_timeout")
        end
      end
    end
  end

  def blocked_by?(waiting_pid, holding_pid)
    ActiveRecord::Base.connection.select_value(
      "SELECT #{Integer(holding_pid)} = ANY(pg_blocking_pids(#{Integer(waiting_pid)}))"
    )
  end

  def await
    Timeout.timeout(6) do
      loop do
        break if yield

        Thread.pass
      end
    end
  end

  def build_tournament_events(pass_first: true, night_capacity: 10)
    owner = create(:user)
    profile = create(:organizer_profile, user: owner)
    org = profile.organization

    if pass_first
      pass_event = create(:event, :published, organizer_profile: profile, organization: org,
        title: "Tournament Pass", max_capacity: 50, starts_at: 2.days.from_now, ends_at: 10.days.from_now)
      night_a = create(:event, :published, organizer_profile: profile, organization: org,
        title: "Night 1", max_capacity: night_capacity, starts_at: 2.days.from_now, ends_at: 2.days.from_now + 3.hours)
      night_b = create(:event, :published, organizer_profile: profile, organization: org,
        title: "Night 2", max_capacity: night_capacity, starts_at: 3.days.from_now, ends_at: 3.days.from_now + 3.hours)
    else
      night_a = create(:event, :published, organizer_profile: profile, organization: org,
        title: "Night 1", max_capacity: night_capacity, starts_at: 2.days.from_now, ends_at: 2.days.from_now + 3.hours)
      night_b = create(:event, :published, organizer_profile: profile, organization: org,
        title: "Night 2", max_capacity: night_capacity, starts_at: 3.days.from_now, ends_at: 3.days.from_now + 3.hours)
      pass_event = create(:event, :published, organizer_profile: profile, organization: org,
        title: "Tournament Pass", max_capacity: 50, starts_at: 2.days.from_now, ends_at: 10.days.from_now)
    end

    pass_tt = create(:ticket_type, event: pass_event, name: "Season Pass", price_cents: 5000, quantity_available: 50)
    TicketTypeIncludedEvent.create!(ticket_type: pass_tt, included_event: night_a, position: 0)
    TicketTypeIncludedEvent.create!(ticket_type: pass_tt, included_event: night_b, position: 1)
    pass_tt.reload

    night_a_tt = create(:ticket_type, event: night_a, name: "Night 1 GA", price_cents: 1000, quantity_available: night_capacity)

    {
      owner: owner,
      org: org,
      pass_event: pass_event,
      night_a: night_a,
      night_b: night_b,
      pass_tt: pass_tt,
      night_a_tt: night_a_tt
    }
  end

  describe "Race 1: Pass checkout/issuance vs Night N daily checkout and cash sale" do
    [true, false].each do |pass_first|
      %i[daily_checkout cash_sale].each do |competitor|
        it "completes without deadlock (pass_first=#{pass_first}, competitor=#{competitor}) and enforces night capacity" do
          ctx = build_tournament_events(pass_first: pass_first, night_capacity: 1)
          pass_locked = Queue.new
          release_pass = Queue.new
          outcomes = Queue.new
          connections = Queue.new

          # Pause pass worker right after it acquires its last event lock (before ticket types)
          max_event_id = [ctx[:pass_event].id, ctx[:night_a].id, ctx[:night_b].id].max
          allow_any_instance_of(Event).to receive(:lock!).and_wrap_original do |original, *args|
            result = original.call(*args)
            if Thread.current[:pass_worker] == :pass && original.receiver.id == max_event_id && !Thread.current[:paused_pass]
              Thread.current[:paused_pass] = true
              pass_locked << true
              Timeout.timeout(8) { release_pass.pop }
            end
            result
          end

          workers = [
            worker(:pass, outcomes, connections) do
              Commerce::OrderCreator.call(
                event: Event.find(ctx[:pass_event].id),
                line_items: [{ ticket_type_id: ctx[:pass_tt].id, quantity: 1 }],
                buyer_email: "pass-buyer@example.invalid",
                buyer_name: "Pass Buyer",
                payment_required: false
              )
            end
          ]

          pass_pid = connections.pop.last
          Timeout.timeout(8) { pass_locked.pop }

          workers << worker(:competitor, outcomes, connections) do
            if competitor == :cash_sale
              Commerce::CashSaleCreator.call(
                event: Event.find(ctx[:night_a].id),
                user: ctx[:owner],
                parameters: { line_items: [{ ticket_type_id: ctx[:night_a_tt].id, quantity: 1 }], payment_method: "door_cash" },
                idempotency_key: "race1-cash-#{pass_first}"
              )
            else
              Commerce::OrderCreator.call(
                event: Event.find(ctx[:night_a].id),
                line_items: [{ ticket_type_id: ctx[:night_a_tt].id, quantity: 1 }],
                buyer_email: "night-buyer@example.invalid",
                buyer_name: "Night Buyer",
                payment_required: false
              )
            end
          end

          competitor_pid = connections.pop.last
          expect(competitor_pid).not_to eq(pass_pid)
          await { blocked_by?(competitor_pid, pass_pid) }

          release_pass << true
          Timeout.timeout(12) { workers.each(&:join) }

          results = 2.times.map { outcomes.pop }.to_h
          expect(results[:pass]).to be_a(Commerce::OrderCreator::Result)
          # Night 1 only had capacity 1; pass took it, so competitor must see capacity exhausted (not deadlock!)
          expect(results[:competitor]).to be_a(Commerce::OrderCreator::CheckoutError)
          expect(results[:competitor].message).to match(/capacity/i)
          expect(EventCapacity.committed_for(ctx[:night_a].reload)).to eq(1)
        ensure
          release_pass << true if release_pass&.empty?
          workers&.each { |thread| thread.kill if thread.alive? }
          workers&.each(&:join)
        end

        it "completes without deadlock when #{competitor} locks Night N first (pass_first=#{pass_first})" do
          ctx = build_tournament_events(pass_first: pass_first, night_capacity: 5)
          night_locked = Queue.new
          release_night = Queue.new
          outcomes = Queue.new
          connections = Queue.new

          allow_any_instance_of(Event).to receive(:lock!).and_wrap_original do |original, *args|
            result = original.call(*args)
            if Thread.current[:pass_worker] == :competitor && original.receiver.id == ctx[:night_a].id && !Thread.current[:paused_night]
              Thread.current[:paused_night] = true
              night_locked << true
              Timeout.timeout(8) { release_night.pop }
            end
            result
          end

          workers = [
            worker(:competitor, outcomes, connections) do
              if competitor == :cash_sale
                Commerce::CashSaleCreator.call(
                  event: Event.find(ctx[:night_a].id),
                  user: ctx[:owner],
                  parameters: { line_items: [{ ticket_type_id: ctx[:night_a_tt].id, quantity: 1 }], payment_method: "door_cash" },
                  idempotency_key: "race1-rev-cash-#{pass_first}"
                )
              else
                Commerce::OrderCreator.call(
                  event: Event.find(ctx[:night_a].id),
                  line_items: [{ ticket_type_id: ctx[:night_a_tt].id, quantity: 1 }],
                  buyer_email: "night-buyer@example.invalid",
                  buyer_name: "Night Buyer",
                  payment_required: false
                )
              end
            end
          ]

          competitor_pid = connections.pop.last
          Timeout.timeout(8) { night_locked.pop }

          workers << worker(:pass, outcomes, connections) do
            Commerce::OrderCreator.call(
              event: Event.find(ctx[:pass_event].id),
              line_items: [{ ticket_type_id: ctx[:pass_tt].id, quantity: 1 }],
              buyer_email: "pass-buyer@example.invalid",
              buyer_name: "Pass Buyer",
              payment_required: false
            )
          end

          pass_pid = connections.pop.last
          expect(pass_pid).not_to eq(competitor_pid)
          await { blocked_by?(pass_pid, competitor_pid) }

          release_night << true
          Timeout.timeout(12) { workers.each(&:join) }

          results = 2.times.map { outcomes.pop }.to_h
          expect(results.values.grep(Exception)).to be_empty, results.inspect
          expect(EventCapacity.committed_for(ctx[:night_a].reload)).to eq(2)
        ensure
          release_night << true if release_night&.empty?
          workers&.each { |thread| thread.kill if thread.alive? }
          workers&.each(&:join)
        end
      end
    end
  end

  describe "Race 5: Pass order completion vs Night N manifest download and admission sync" do
    %i[manifest sync].each do |door_op|
      it "completes pass OrderLifecycle.complete! against Night N #{door_op} without lock cycle" do
        ctx = build_tournament_events(pass_first: false, night_capacity: 10)
        staff = create(:user)
        create(:organization_membership, organization: ctx[:org], user: staff, role: :manager)
        headers = auth_headers(staff).merge("X-Organization-Id" => ctx[:org].id.to_s)
        device = Admissions::DeviceRegistrar.call(event: ctx[:night_a], user: staff, identifier: "race5-#{door_op}", name: "Gate 1")

        # Existing ticket on Night 1 for sync
        existing_daily_order = Commerce::OrderCreator.call(
          event: ctx[:night_a],
          line_items: [{ ticket_type_id: ctx[:night_a_tt].id, quantity: 1 }],
          buyer_email: "daily@example.invalid",
          buyer_name: "Daily Attendee",
          payment_required: false
        ).order
        daily_ticket = existing_daily_order.tickets.sole
        manifest = Admissions::ManifestBuilder.call(event: ctx[:night_a], actor: staff)
        sync_payload = {
          actions: [{
            action_uuid: SecureRandom.uuid,
            sequence: 1,
            kind: "admit",
            source: "online",
            ticket_id: daily_ticket.id,
            credential_hash: Digest::SHA256.hexdigest(daily_ticket.scan_credential),
            manifest_version: manifest.version,
            occurred_at: Time.current.iso8601(6)
          }]
        }

        # Pending paid pass order ready for completion
        pending_result = Commerce::OrderCreator.call(
          event: ctx[:pass_event],
          line_items: [{ ticket_type_id: ctx[:pass_tt].id, quantity: 1 }],
          buyer_email: "pending-pass@example.invalid",
          buyer_name: "Pending Pass",
          payment_required: true
        )
        pass_order = pending_result.order
        pass_payment = pending_result.payment

        completion_ready = Queue.new
        release_completion = Queue.new
        outcomes = Queue.new
        connections = Queue.new

        allow(AuditLogger).to receive(:write!).and_wrap_original do |original, **args|
          if Thread.current[:pass_worker] == :completion && args[:action] == "order.completed" && !Thread.current[:paused_audit]
            Thread.current[:paused_audit] = true
            completion_ready << true
            Timeout.timeout(8) { release_completion.pop }
          end
          original.call(**args)
        end

        workers = [
          worker(:completion, outcomes, connections) do
            Commerce::OrderLifecycle.complete!(
              Order.find(pass_order.id),
              payment: Payment.find(pass_payment.id),
              provider_amount_cents: pass_payment.amount_cents,
              provider_currency: pass_payment.currency
            )
          end
        ]

        completion_pid = connections.pop.last
        Timeout.timeout(8) { completion_ready.pop }

        workers << worker(:door, outcomes, connections) do
          client = ActionDispatch::Integration::Session.new(Rails.application)
          base = "/api/v1/organizer/events/#{ctx[:night_a].id}/scanner_devices/#{device.id}"
          if door_op == :manifest
            client.get "#{base}/manifest", headers: headers
          else
            client.post "#{base}/sync", params: sync_payload, headers: headers
          end
          [client.response.status, client.response.parsed_body]
        end

        door_pid = connections.pop.last
        expect(door_pid).not_to eq(completion_pid)
        await { blocked_by?(door_pid, completion_pid) }

        release_completion << true
        Timeout.timeout(12) { workers.each(&:join) }

        results = 2.times.map { outcomes.pop }.to_h
        expect(results.values.grep(Exception)).to be_empty, results.inspect
        expect(results[:completion]).to eq(:completed)
        expect(results[:door].first).to eq(200)
        expect(pass_order.reload).to be_completed
        expect(pass_order.tickets.where.not(parent_ticket_id: nil).count).to eq(2)
        expect(daily_ticket.reload).to be_checked_in if door_op == :sync
        expect(AuditWriteFailure.count).to eq(0)
      ensure
        release_completion << true if release_completion&.empty?
        workers&.each { |thread| thread.kill if thread.alive? }
        workers&.each(&:join)
      end
    end
  end

  describe "Race 6: sync_pass_holders vs Night N admission sync and Night N daily checkout" do
    %i[admission_sync night_checkout].each do |competitor|
      it "completes sync_pass_holders against #{competitor} without deadlock" do
        ctx = build_tournament_events(pass_first: true, night_capacity: 10)
        staff = create(:user)
        create(:organization_membership, organization: ctx[:org], user: staff, role: :manager)
        headers = auth_headers(staff).merge("X-Organization-Id" => ctx[:org].id.to_s)

        # Sell a pass first (covers night_a and night_b)
        pass_order = Commerce::OrderCreator.call(
          event: ctx[:pass_event],
          line_items: [{ ticket_type_id: ctx[:pass_tt].id, quantity: 1 }],
          buyer_email: "holder@example.invalid",
          buyer_name: "Pass Holder",
          payment_required: false
        ).order

        # Add a third night to the pass so sync_pass_holders has missing child work to do
        night_c = create(:event, :published, organizer_profile: ctx[:pass_event].organizer_profile, organization: ctx[:org],
          title: "Championship Night", max_capacity: 10, starts_at: 4.days.from_now, ends_at: 4.days.from_now + 3.hours)
        night_c_tt = create(:ticket_type, event: night_c, name: "Finals GA", price_cents: 1500, quantity_available: 10)
        TicketTypeIncludedEvent.create!(ticket_type: ctx[:pass_tt], included_event: night_c, position: 2)

        # Prepare admission sync on night_a (already has pass child ticket)
        device = Admissions::DeviceRegistrar.call(event: ctx[:night_a], user: staff, identifier: "race6-#{competitor}", name: "Gate A")
        night_a_child = pass_order.tickets.find_by!(event: ctx[:night_a])
        manifest = Admissions::ManifestBuilder.call(event: ctx[:night_a], actor: staff)
        sync_payload = {
          actions: [{
            action_uuid: SecureRandom.uuid,
            sequence: 1,
            kind: "admit",
            source: "online",
            ticket_id: night_a_child.id,
            credential_hash: Digest::SHA256.hexdigest(night_a_child.scan_credential),
            manifest_version: manifest.version,
            occurred_at: Time.current.iso8601(6)
          }]
        }

        sync_ready = Queue.new
        release_sync = Queue.new
        outcomes = Queue.new
        connections = Queue.new

        allow(AuditLogger).to receive(:write!).and_wrap_original do |original, **args|
          if Thread.current[:pass_worker] == :sync_holders && args[:action] == "ticket_type.pass_holders_synced" && !Thread.current[:paused_sync]
            Thread.current[:paused_sync] = true
            sync_ready << true
            Timeout.timeout(8) { release_sync.pop }
          end
          original.call(**args)
        end

        workers = [
          worker(:sync_holders, outcomes, connections) do
            client = ActionDispatch::Integration::Session.new(Rails.application)
            client.post "/api/v1/organizer/events/#{ctx[:pass_event].id}/ticket_types/#{ctx[:pass_tt].id}/sync_pass_holders",
              headers: headers
            [client.response.status, client.response.parsed_body]
          end
        ]

        sync_pid = connections.pop.last
        Timeout.timeout(8) { sync_ready.pop }

        workers << worker(:competitor, outcomes, connections) do
          if competitor == :admission_sync
            client = ActionDispatch::Integration::Session.new(Rails.application)
            client.post "/api/v1/organizer/events/#{ctx[:night_a].id}/scanner_devices/#{device.id}/sync",
              params: sync_payload, headers: headers
            [client.response.status, client.response.parsed_body]
          else
            Commerce::OrderCreator.call(
              event: Event.find(night_c.id),
              line_items: [{ ticket_type_id: night_c_tt.id, quantity: 1 }],
              buyer_email: "finals@example.invalid",
              buyer_name: "Finals Buyer",
              payment_required: false
            )
          end
        end

        competitor_pid = connections.pop.last
        expect(competitor_pid).not_to eq(sync_pid)
        await { blocked_by?(competitor_pid, sync_pid) }

        release_sync << true
        Timeout.timeout(12) { workers.each(&:join) }

        results = 2.times.map { outcomes.pop }.to_h
        expect(results.values.grep(Exception)).to be_empty, results.inspect
        expect(results[:sync_holders].first).to eq(200)
        expect(results[:sync_holders].last.fetch("issued_ticket_count")).to eq(1)
        if competitor == :admission_sync
          expect(results[:competitor].first).to eq(200)
          expect(night_a_child.reload).to be_checked_in
        else
          expect(results[:competitor]).to be_a(Commerce::OrderCreator::Result)
        end
        expect(pass_order.tickets.where(event: night_c).count).to eq(1)
        expect(AuditWriteFailure.count).to eq(0)
      ensure
        release_sync << true if release_sync&.empty?
        workers&.each { |thread| thread.kill if thread.alive? }
        workers&.each(&:join)
      end
    end
  end

  describe "Overlapping passes: two concurrent pass checkouts sharing a night" do
    it "completes without deadlock and enforces exact shared night capacity" do
      owner = create(:user)
      profile = create(:organizer_profile, user: owner)
      org = profile.organization

      pass_event_1 = create(:event, :published, organizer_profile: profile, organization: org,
        title: "Pass A", max_capacity: 20, starts_at: 2.days.from_now, ends_at: 10.days.from_now)
      night_a = create(:event, :published, organizer_profile: profile, organization: org,
        title: "Night A", max_capacity: 10, starts_at: 2.days.from_now, ends_at: 2.days.from_now + 3.hours)
      night_shared = create(:event, :published, organizer_profile: profile, organization: org,
        title: "Shared Finals Night", max_capacity: 1, starts_at: 3.days.from_now, ends_at: 3.days.from_now + 3.hours)
      night_b = create(:event, :published, organizer_profile: profile, organization: org,
        title: "Night B", max_capacity: 10, starts_at: 4.days.from_now, ends_at: 4.days.from_now + 3.hours)
      pass_event_2 = create(:event, :published, organizer_profile: profile, organization: org,
        title: "Pass B", max_capacity: 20, starts_at: 2.days.from_now, ends_at: 10.days.from_now)

      pass_tt_1 = create(:ticket_type, event: pass_event_1, name: "Pass A", price_cents: 4000, quantity_available: 10)
      TicketTypeIncludedEvent.create!(ticket_type: pass_tt_1, included_event: night_a, position: 0)
      TicketTypeIncludedEvent.create!(ticket_type: pass_tt_1, included_event: night_shared, position: 1)

      pass_tt_2 = create(:ticket_type, event: pass_event_2, name: "Pass B", price_cents: 4000, quantity_available: 10)
      TicketTypeIncludedEvent.create!(ticket_type: pass_tt_2, included_event: night_shared, position: 0)
      TicketTypeIncludedEvent.create!(ticket_type: pass_tt_2, included_event: night_b, position: 1)

      pass_1_locked = Queue.new
      release_pass_1 = Queue.new
      outcomes = Queue.new
      connections = Queue.new

      pass_1_max_id = [pass_event_1.id, night_a.id, night_shared.id].max
      allow_any_instance_of(Event).to receive(:lock!).and_wrap_original do |original, *args|
        result = original.call(*args)
        if Thread.current[:pass_worker] == :pass_1 && original.receiver.id == pass_1_max_id && !Thread.current[:paused_pass_1]
          Thread.current[:paused_pass_1] = true
          pass_1_locked << true
          Timeout.timeout(8) { release_pass_1.pop }
        end
        result
      end

      workers = [
        worker(:pass_1, outcomes, connections) do
          Commerce::OrderCreator.call(
            event: Event.find(pass_event_1.id),
            line_items: [{ ticket_type_id: pass_tt_1.id, quantity: 1 }],
            buyer_email: "pass1@example.invalid",
            buyer_name: "Pass 1 Buyer",
            payment_required: false
          )
        end
      ]

      pass_1_pid = connections.pop.last
      Timeout.timeout(8) { pass_1_locked.pop }

      workers << worker(:pass_2, outcomes, connections) do
        Commerce::OrderCreator.call(
          event: Event.find(pass_event_2.id),
          line_items: [{ ticket_type_id: pass_tt_2.id, quantity: 1 }],
          buyer_email: "pass2@example.invalid",
          buyer_name: "Pass 2 Buyer",
          payment_required: false
        )
      end

      pass_2_pid = connections.pop.last
      expect(pass_2_pid).not_to eq(pass_1_pid)
      await { blocked_by?(pass_2_pid, pass_1_pid) }

      release_pass_1 << true
      Timeout.timeout(12) { workers.each(&:join) }

      results = 2.times.map { outcomes.pop }.to_h
      expect(results[:pass_1]).to be_a(Commerce::OrderCreator::Result)
      expect(results[:pass_2]).to be_a(Commerce::OrderCreator::CheckoutError)
      expect(results[:pass_2].message).to include("Shared Finals Night")
      expect(EventCapacity.committed_for(night_shared.reload)).to eq(1)
    ensure
      release_pass_1 << true if release_pass_1&.empty?
      workers&.each { |thread| thread.kill if thread.alive? }
      workers&.each(&:join)
    end
  end

  def create_completed_paid_pass_order(ctx, buyer_email: "pass-paid@example.invalid", buyer_name: "Paid Pass Fan")
    checkout = Commerce::OrderCreator.call(
      event: ctx[:pass_event],
      line_items: [{ ticket_type_id: ctx[:pass_tt].id, quantity: 1 }],
      buyer_email: buyer_email,
      buyer_name: buyer_name,
      payment_required: true
    )
    Commerce::OrderLifecycle.complete!(
      checkout.order,
      payment: checkout.payment,
      provider_amount_cents: checkout.payment.amount_cents,
      provider_currency: checkout.payment.currency
    )
    [checkout.order.reload, checkout.payment.reload]
  end

  describe "Race 2: Pass Refund (RefundCreator) vs Night N Checkout and Cash Sale" do
    before do
      allow(EmailService).to receive(:send_refund_notification_async)
      allow(StripeService).to receive(:refund_payment) do |_pi, amount_cents:, **|
        OpenStruct.new(id: "re_race2_#{SecureRandom.hex(6)}", status: "succeeded", amount: amount_cents, currency: "usd")
      end
    end

    %i[daily_checkout cash_sale].each do |competitor|
      it "completes Pass Refund while #{competitor} holds Night N lock (proving Pass Refund never locks Night N)" do
        ctx = build_tournament_events(pass_first: false, night_capacity: 10)
        pass_order, = create_completed_paid_pass_order(ctx)
        parent = pass_order.tickets.find_by!(parent_ticket_id: nil)

        night_locked = Queue.new
        release_night = Queue.new
        outcomes = Queue.new
        connections = Queue.new

        allow_any_instance_of(Event).to receive(:lock!).and_wrap_original do |original, *args|
          result = original.call(*args)
          if Thread.current[:pass_worker] == :competitor && original.receiver.id == ctx[:night_a].id && !Thread.current[:paused_night]
            Thread.current[:paused_night] = true
            night_locked << true
            Timeout.timeout(8) { release_night.pop }
          end
          result
        end

        workers = [
          worker(:competitor, outcomes, connections) do
            if competitor == :cash_sale
              Commerce::CashSaleCreator.call(
                event: Event.find(ctx[:night_a].id),
                user: ctx[:owner],
                parameters: { line_items: [{ ticket_type_id: ctx[:night_a_tt].id, quantity: 1 }], payment_method: "door_cash" },
                idempotency_key: "race2-cash-first"
              )
            else
              Commerce::OrderCreator.call(
                event: Event.find(ctx[:night_a].id),
                line_items: [{ ticket_type_id: ctx[:night_a_tt].id, quantity: 1 }],
                buyer_email: "night-r2@example.invalid",
                buyer_name: "Night R2",
                payment_required: false
              )
            end
          end
        ]

        competitor_pid = connections.pop.last
        Timeout.timeout(8) { night_locked.pop }

        # Pass refund MUST complete cleanly WITHOUT waiting on night_a's lock!
        workers << worker(:refund, outcomes, connections) do
          Commerce::RefundCreator.call(
            order: Order.find(pass_order.id),
            tickets: [Ticket.find(parent.id)],
            reason: "requested_by_customer",
            requested_by: ctx[:owner],
            idempotency_key: "race2-pass-refund-#{competitor}"
          )
        end

        refund_pid = connections.pop.last
        expect(refund_pid).not_to eq(competitor_pid)

        # Wait for refund worker to FINISH while competitor STILL holds night_a's lock!
        first_done_name, first_done_result = Timeout.timeout(8) { outcomes.pop }
        expect(first_done_name).to eq(:refund)
        expect(first_done_result).to be_a(Refund)
        expect(first_done_result).to be_succeeded

        release_night << true
        Timeout.timeout(12) { workers.each(&:join) }

        second_done_name, second_done_result = Timeout.timeout(8) { outcomes.pop }
        expect(second_done_name).to eq(:competitor)
        expect(second_done_result).not_to be_a(Exception), second_done_result.inspect
        expect(pass_order.reload).to be_refunded
        expect(pass_order.tickets.pluck(:status).uniq).to eq(["cancelled"])
        expect(ctx[:pass_tt].reload.quantity_sold).to eq(0)
        expect(AuditWriteFailure.count).to eq(0)
      ensure
        release_night << true if release_night&.empty?
        workers&.each { |thread| thread.kill if thread.alive? }
        workers&.each(&:join)
      end

      it "completes without deadlock when Pass Refund holds ORG lock before #{competitor} runs" do
        ctx = build_tournament_events(pass_first: true, night_capacity: 10)
        pass_order, = create_completed_paid_pass_order(ctx)
        parent = pass_order.tickets.find_by!(parent_ticket_id: nil)

        refund_locked = Queue.new
        release_refund = Queue.new
        outcomes = Queue.new
        connections = Queue.new

        allow_any_instance_of(Order).to receive(:lock!).and_wrap_original do |original, *args|
          result = original.call(*args)
          if Thread.current[:pass_worker] == :refund && original.receiver.id == pass_order.id && !Thread.current[:paused_refund]
            Thread.current[:paused_refund] = true
            refund_locked << true
            Timeout.timeout(8) { release_refund.pop }
          end
          result
        end

        workers = [
          worker(:refund, outcomes, connections) do
            Commerce::RefundCreator.call(
              order: Order.find(pass_order.id),
              tickets: [Ticket.find(parent.id)],
              reason: "requested_by_customer",
              requested_by: ctx[:owner],
              idempotency_key: "race2-org-first-#{competitor}"
            )
          end
        ]

        refund_pid = connections.pop.last
        Timeout.timeout(8) { refund_locked.pop }

        workers << worker(:competitor, outcomes, connections) do
          if competitor == :cash_sale
            Commerce::CashSaleCreator.call(
              event: Event.find(ctx[:night_a].id),
              user: ctx[:owner],
              parameters: { line_items: [{ ticket_type_id: ctx[:night_a_tt].id, quantity: 1 }], payment_method: "door_cash" },
              idempotency_key: "race2-cash-after-org"
            )
          else
            Commerce::OrderCreator.call(
              event: Event.find(ctx[:night_a].id),
              line_items: [{ ticket_type_id: ctx[:night_a_tt].id, quantity: 1 }],
              buyer_email: "night-r2-after@example.invalid",
              buyer_name: "Night R2 After",
              payment_required: false
            )
          end
        end

        competitor_pid = connections.pop.last
        expect(competitor_pid).not_to eq(refund_pid)
        release_refund << true
        Timeout.timeout(12) { workers.each(&:join) }

        results = 2.times.map { outcomes.pop }.to_h
        expect(results.values.grep(Exception)).to be_empty, results.inspect
        expect(pass_order.reload).to be_refunded
        expect(AuditWriteFailure.count).to eq(0)
      ensure
        release_refund << true if release_refund&.empty?
        workers&.each { |thread| thread.kill if thread.alive? }
        workers&.each(&:join)
      end
    end
  end

  describe "Race 3: Pass Lost Dispute (StripeWebhookProcessor) vs Night N Checkout and Cash Sale" do
    before do
      allow(StripeService).to receive(:verify_payment_context!).and_return(true)
    end

    %i[daily_checkout cash_sale].each do |competitor|
      it "completes Pass Lost Dispute while #{competitor} holds Night N lock without deadlock" do
        ctx = build_tournament_events(pass_first: false, night_capacity: 10)
        pass_order, pass_payment = create_completed_paid_pass_order(ctx)

        night_locked = Queue.new
        release_night = Queue.new
        outcomes = Queue.new
        connections = Queue.new

        allow_any_instance_of(Event).to receive(:lock!).and_wrap_original do |original, *args|
          result = original.call(*args)
          if Thread.current[:pass_worker] == :competitor && original.receiver.id == ctx[:night_a].id && !Thread.current[:paused_night]
            Thread.current[:paused_night] = true
            night_locked << true
            Timeout.timeout(8) { release_night.pop }
          end
          result
        end

        workers = [
          worker(:competitor, outcomes, connections) do
            if competitor == :cash_sale
              Commerce::CashSaleCreator.call(
                event: Event.find(ctx[:night_a].id),
                user: ctx[:owner],
                parameters: { line_items: [{ ticket_type_id: ctx[:night_a_tt].id, quantity: 1 }], payment_method: "door_cash" },
                idempotency_key: "race3-cash"
              )
            else
              Commerce::OrderCreator.call(
                event: Event.find(ctx[:night_a].id),
                line_items: [{ ticket_type_id: ctx[:night_a_tt].id, quantity: 1 }],
                buyer_email: "night-r3@example.invalid",
                buyer_name: "Night R3",
                payment_required: false
              )
            end
          end
        ]

        competitor_pid = connections.pop.last
        Timeout.timeout(8) { night_locked.pop }

        dispute_event = OpenStruct.new(
          id: "evt_race3_#{competitor}",
          type: "charge.dispute.closed",
          created: Time.current.to_i,
          data: OpenStruct.new(
            object: {
              "id" => "dp_race3_#{competitor}",
              "payment_intent" => pass_payment.provider_payment_id,
              "amount" => pass_order.total_cents,
              "currency" => pass_order.currency,
              "reason" => "fraudulent",
              "status" => "lost"
            }
          )
        )

        workers << worker(:dispute, outcomes, connections) do
          StripeWebhookProcessor.call(event: dispute_event, payload: { "id" => dispute_event.id, "type" => dispute_event.type })
        end

        dispute_pid = connections.pop.last
        expect(dispute_pid).not_to eq(competitor_pid)

        # Lost dispute completes while competitor still holds night_a lock
        first_name, first_res = Timeout.timeout(8) { outcomes.pop }
        expect(first_name).to eq(:dispute)
        expect(first_res).not_to be_a(Exception), first_res.inspect

        release_night << true
        Timeout.timeout(12) { workers.each(&:join) }

        second_name, second_res = Timeout.timeout(8) { outcomes.pop }
        expect(second_name).to eq(:competitor)
        expect(second_res).not_to be_a(Exception), second_res.inspect
        expect(pass_order.tickets.reload.pluck(:status).uniq).to eq(["cancelled"])
        expect(ctx[:pass_tt].reload.quantity_sold).to eq(0)
        expect(AuditWriteFailure.count).to eq(0)
      ensure
        release_night << true if release_night&.empty?
        workers&.each { |thread| thread.kill if thread.alive? }
        workers&.each(&:join)
      end
    end
  end

  describe "Race 4: Pass Refund / Dispute vs Night N Admission Sync (Admissions::Reconciler)" do
    before do
      allow(EmailService).to receive(:send_refund_notification_async)
      allow(StripeService).to receive(:verify_payment_context!).and_return(true)
      allow(StripeService).to receive(:refund_payment) do |_pi, amount_cents:, **|
        OpenStruct.new(id: "re_race4_#{SecureRandom.hex(6)}", status: "succeeded", amount: amount_cents, currency: "usd")
      end
    end

    it "serializes Pass Refund first vs Night N Admission Sync cleanly at ORG without deadlock" do
      ctx = build_tournament_events(pass_first: false, night_capacity: 10)
      staff = create(:user)
      create(:organization_membership, organization: ctx[:org], user: staff, role: :manager)
      headers = auth_headers(staff).merge("X-Organization-Id" => ctx[:org].id.to_s)
      pass_order, = create_completed_paid_pass_order(ctx)
      parent = pass_order.tickets.find_by!(parent_ticket_id: nil)
      night_a_child = pass_order.tickets.find_by!(event: ctx[:night_a])
      device = Admissions::DeviceRegistrar.call(event: ctx[:night_a], user: staff, identifier: "race4-ref", name: "Gate R4")
      manifest = Admissions::ManifestBuilder.call(event: ctx[:night_a], actor: staff)
      sync_payload = {
        actions: [{
          action_uuid: SecureRandom.uuid,
          sequence: 1,
          kind: "admit",
          source: "online",
          ticket_id: night_a_child.id,
          credential_hash: Digest::SHA256.hexdigest(night_a_child.scan_credential),
          manifest_version: manifest.version,
          occurred_at: Time.current.iso8601(6)
        }]
      }

      refund_locked = Queue.new
      release_refund = Queue.new
      outcomes = Queue.new
      connections = Queue.new

      allow_any_instance_of(Order).to receive(:lock!).and_wrap_original do |original, *args|
        result = original.call(*args)
        if Thread.current[:pass_worker] == :refund && original.receiver.id == pass_order.id && !Thread.current[:paused_refund]
          Thread.current[:paused_refund] = true
          refund_locked << true
          Timeout.timeout(8) { release_refund.pop }
        end
        result
      end

      workers = [
        worker(:refund, outcomes, connections) do
          Commerce::RefundCreator.call(
            order: Order.find(pass_order.id),
            tickets: [Ticket.find(parent.id)],
            reason: "requested_by_customer",
            requested_by: ctx[:owner],
            idempotency_key: "race4-refund-first"
          )
        end
      ]

      refund_pid = connections.pop.last
      Timeout.timeout(8) { refund_locked.pop }

      workers << worker(:sync, outcomes, connections) do
        client = ActionDispatch::Integration::Session.new(Rails.application)
        client.post "/api/v1/organizer/events/#{ctx[:night_a].id}/scanner_devices/#{device.id}/sync",
          params: sync_payload, headers: headers
        [client.response.status, client.response.parsed_body]
      end

      sync_pid = connections.pop.last
      expect(sync_pid).not_to eq(refund_pid)
      await { blocked_by?(sync_pid, refund_pid) }

      release_refund << true
      Timeout.timeout(12) { workers.each(&:join) }

      results = 2.times.map { outcomes.pop }.to_h
      expect(results.values.grep(Exception)).to be_empty, results.inspect
      expect(results[:refund]).to be_succeeded
      expect(results[:sync].first).to eq(200)
      # Child ticket is blocked either immediately after reserve_refund! (refund_pending)
      # or after finalize_observed_refund! (credential_revoked / cancelled).
      action = results[:sync].last.fetch("results").sole
      expect(action["result"]).to eq("rejected")
      expect(%w[refund_pending credential_revoked cancelled]).to include(action["reason_code"])
      expect(night_a_child.reload).to be_cancelled
    ensure
      release_refund << true if release_refund&.empty?
      workers&.each { |thread| thread.kill if thread.alive? }
      workers&.each(&:join)
    end

    it "serializes Night N Admission Sync first vs Pass Lost Dispute cleanly at ORG (retaining parent + cancelling Night 2)" do
      ctx = build_tournament_events(pass_first: false, night_capacity: 10)
      staff = create(:user)
      create(:organization_membership, organization: ctx[:org], user: staff, role: :manager)
      headers = auth_headers(staff).merge("X-Organization-Id" => ctx[:org].id.to_s)
      pass_order, pass_payment = create_completed_paid_pass_order(ctx)
      parent = pass_order.tickets.find_by!(parent_ticket_id: nil)
      night_a_child = pass_order.tickets.find_by!(event: ctx[:night_a])
      night_b_child = pass_order.tickets.find_by!(event: ctx[:night_b])
      device = Admissions::DeviceRegistrar.call(event: ctx[:night_a], user: staff, identifier: "race4-disp", name: "Gate R4D")
      manifest = Admissions::ManifestBuilder.call(event: ctx[:night_a], actor: staff)
      sync_payload = {
        actions: [{
          action_uuid: SecureRandom.uuid,
          sequence: 1,
          kind: "admit",
          source: "online",
          ticket_id: night_a_child.id,
          credential_hash: Digest::SHA256.hexdigest(night_a_child.scan_credential),
          manifest_version: manifest.version,
          occurred_at: Time.current.iso8601(6)
        }]
      }

      sync_locked = Queue.new
      release_sync = Queue.new
      outcomes = Queue.new
      connections = Queue.new

      allow_any_instance_of(Event).to receive(:lock!).and_wrap_original do |original, *args|
        result = original.call(*args)
        if Thread.current[:pass_worker] == :sync && original.receiver.id == ctx[:night_a].id && !Thread.current[:paused_sync]
          Thread.current[:paused_sync] = true
          sync_locked << true
          Timeout.timeout(8) { release_sync.pop }
        end
        result
      end

      workers = [
        worker(:sync, outcomes, connections) do
          client = ActionDispatch::Integration::Session.new(Rails.application)
          client.post "/api/v1/organizer/events/#{ctx[:night_a].id}/scanner_devices/#{device.id}/sync",
            params: sync_payload, headers: headers
          [client.response.status, client.response.parsed_body]
        end
      ]

      sync_pid = connections.pop.last
      Timeout.timeout(8) { sync_locked.pop }

      dispute_event = OpenStruct.new(
        id: "evt_race4_dispute",
        type: "charge.dispute.closed",
        created: Time.current.to_i,
        data: OpenStruct.new(
          object: {
            "id" => "dp_race4_dispute",
            "payment_intent" => pass_payment.provider_payment_id,
            "amount" => pass_order.total_cents,
            "currency" => pass_order.currency,
            "reason" => "fraudulent",
            "status" => "lost"
          }
        )
      )

      workers << worker(:dispute, outcomes, connections) do
        StripeWebhookProcessor.call(event: dispute_event, payload: { "id" => dispute_event.id, "type" => dispute_event.type })
      end

      dispute_pid = connections.pop.last
      expect(dispute_pid).not_to eq(sync_pid)
      await { blocked_by?(dispute_pid, sync_pid) }

      release_sync << true
      Timeout.timeout(12) { workers.each(&:join) }

      results = 2.times.map { outcomes.pop }.to_h
      expect(results.values.grep(Exception)).to be_empty, results.inspect
      expect(results[:sync].first).to eq(200)
      expect(night_a_child.reload).to be_checked_in
      expect(night_b_child.reload).to be_cancelled
      expect(parent.reload).to be_inventory_retained
      expect(ctx[:pass_tt].reload.quantity_sold).to eq(1)
      expect(ReconciliationException.where(order: pass_order, code: "admitted_inventory_retained").count).to eq(1)
    ensure
      release_sync << true if release_sync&.empty?
      workers&.each { |thread| thread.kill if thread.alive? }
      workers&.each(&:join)
    end
  end

  describe "Race 7: Pass Refund on Order A vs Pass Checkout on Order B (same pass event)" do
    before do
      allow(EmailService).to receive(:send_refund_notification_async)
      allow(StripeService).to receive(:refund_payment) do |_pi, amount_cents:, **|
        OpenStruct.new(id: "re_race7_#{SecureRandom.hex(6)}", status: "succeeded", amount: amount_cents, currency: "usd")
      end
    end

    %i[checkout_first refund_first].each do |ordering|
      it "completes without deadlock (ordering=#{ordering})" do
        ctx = build_tournament_events(pass_first: true, night_capacity: 10)
        order_a, = create_completed_paid_pass_order(ctx, buyer_email: "order-a@example.invalid", buyer_name: "Buyer A")
        parent_a = order_a.tickets.find_by!(parent_ticket_id: nil)

        first_locked = Queue.new
        release_first = Queue.new
        outcomes = Queue.new
        connections = Queue.new

        if ordering == :checkout_first
          max_event_id = [ctx[:pass_event].id, ctx[:night_a].id, ctx[:night_b].id].max
          allow_any_instance_of(Event).to receive(:lock!).and_wrap_original do |original, *args|
            result = original.call(*args)
            if Thread.current[:pass_worker] == :checkout_b && original.receiver.id == max_event_id && !Thread.current[:paused_b]
              Thread.current[:paused_b] = true
              first_locked << true
              Timeout.timeout(8) { release_first.pop }
            end
            result
          end
        else
          allow_any_instance_of(Order).to receive(:lock!).and_wrap_original do |original, *args|
            result = original.call(*args)
            if Thread.current[:pass_worker] == :refund_a && original.receiver.id == order_a.id && !Thread.current[:paused_a]
              Thread.current[:paused_a] = true
              first_locked << true
              Timeout.timeout(8) { release_first.pop }
            end
            result
          end
        end

        run_checkout_b = lambda do
          Commerce::OrderCreator.call(
            event: Event.find(ctx[:pass_event].id),
            line_items: [{ ticket_type_id: ctx[:pass_tt].id, quantity: 1 }],
            buyer_email: "order-b@example.invalid",
            buyer_name: "Buyer B",
            payment_required: false
          )
        end
        run_refund_a = lambda do
          Commerce::RefundCreator.call(
            order: Order.find(order_a.id),
            tickets: [Ticket.find(parent_a.id)],
            reason: "requested_by_customer",
            requested_by: ctx[:owner],
            idempotency_key: "race7-refund-a-#{ordering}"
          )
        end

        workers = []
        if ordering == :checkout_first
          workers << worker(:checkout_b, outcomes, connections, &run_checkout_b)
          first_pid = connections.pop.last
          Timeout.timeout(8) { first_locked.pop }
          workers << worker(:refund_a, outcomes, connections, &run_refund_a)
          second_pid = connections.pop.last
        else
          workers << worker(:refund_a, outcomes, connections, &run_refund_a)
          first_pid = connections.pop.last
          Timeout.timeout(8) { first_locked.pop }
          workers << worker(:checkout_b, outcomes, connections, &run_checkout_b)
          second_pid = connections.pop.last
        end

        expect(second_pid).not_to eq(first_pid)
        await { blocked_by?(second_pid, first_pid) }

        release_first << true
        Timeout.timeout(12) { workers.each(&:join) }

        results = 2.times.map { outcomes.pop }.to_h
        expect(results.values.grep(Exception)).to be_empty, results.inspect
        expect(results[:refund_a]).to be_succeeded
        expect(results[:checkout_b]).to be_a(Commerce::OrderCreator::Result)
        expect(order_a.reload).to be_refunded
        expect(results[:checkout_b].order.reload).to be_completed
        expect(ctx[:pass_tt].reload.quantity_sold).to eq(1)
        expect(AuditWriteFailure.count).to eq(0)
      ensure
        release_first << true if release_first&.empty?
        workers&.each { |thread| thread.kill if thread.alive? }
        workers&.each(&:join)
      end
    end
  end
end
