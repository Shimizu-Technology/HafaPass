# frozen_string_literal: true

require "rails_helper"
require "timeout"

RSpec.describe "Ticket mutation and admission lock ordering", type: :request, webmock: true do
  self.use_transactional_tests = false

  before do
    raise "Ticket concurrency tests require PostgreSQL test" unless Rails.env.test? &&
      ActiveRecord::Base.connection.adapter_name == "PostgreSQL"

    clean_data
    allow(EmailService).to receive(:send_ticket_transfer_async)
    allow(Stripe::StripeClient).to receive(:new).and_raise("NO PROVIDER CLIENTS ALLOWED")
    @event = create(:event, :published, starts_at: 1.day.from_now)
    @staff = create(:user)
    create(:organization_membership, organization: @event.organization, user: @staff, role: :manager)
    @headers = auth_headers(@staff).merge("X-Organization-Id" => @event.organization_id.to_s)
    @buyer = create(:user)
    @recipient = create(:user)
    @buyer_headers = auth_headers(@buyer)
    allow(ClerkIdentity).to receive(:verified_email_addresses).with(@buyer.clerk_id, require_available: true).and_return([@buyer.email])
    @recipient_headers = auth_headers(@recipient)
    @direct_headers = auth_headers(@event.organizer_profile.user)
    @type = create(:ticket_type, event: @event, quantity_sold: 1, quantity_available: 10)
    @order = create(:order, event: @event, user: @buyer, buyer_email: @buyer.email)
    @ticket = create(:ticket, event: @event, order: @order, ticket_type: @type)
    @device = Admissions::DeviceRegistrar.call(event: @event, user: @staff, identifier: "ticket-race", name: "Gate")
    @base = "/api/v1/organizer/events/#{@event.id}/scanner_devices/#{@device.id}"
  end

  after { clean_data }

  %i[sync recover].each do |operation|
    %i[rotate create accept direct cancel expire free_cancel guest lifecycle seat].each do |mutation|
      it "finishes #{operation} versus #{mutation} at the real audit boundary without a lock cycle" do
        transfer = nil
        token = nil
        if %i[accept cancel expire].include?(mutation)
          transfer = TicketTransfers::Manager.create!(ticket: @ticket, recipient_email: @recipient.email, initiated_by: @buyer)
          token = TicketTransferCredential.issue(transfer)
          transfer.update_columns(expires_at: 1.minute.ago) if mutation == :expire
        elsif mutation == :guest
          @order.update!(user: nil)
          @ticket.update!(holder_user: nil)
        end
        pending_order = create(:order, :pending, event: @event) if mutation == :lifecycle
        if mutation == :seat
          @event.update!(venue: create(:venue))
          configuration = create(:event_seating_configuration, event: @event)
          original_seat = create(:event_seat, event_seating_configuration: configuration, ticket_type: @type)
          target_seat = create(:event_seat, event_seating_configuration: configuration, ticket_type: @type)
          @ticket.update!(event_seat: original_seat)
        end
        prepare_manifest
        old_version = @ticket.scan_credential_version
        old_display = @ticket.display_credential
        old_scan = @ticket.scan_credential
        audit_action = { rotate: "ticket.scan_credential_rotated", create: "ticket_transfer.created",
          accept: "ticket.scan_credential_rotated", direct: "ticket.checked_in", cancel: "ticket_transfer.cancelled",
          expire: "ticket_transfer.expired", free_cancel: "ticket.cancelled", guest: "guest_purchase.recovered",
          lifecycle: "order.cancelled", seat: "ticket.scan_credential_rotated" }.fetch(mutation)
        audit_ready, release_audit = Queue.new, Queue.new
        outcomes, connections = Queue.new, Queue.new
        allow(AuditLogger).to receive(:write!).and_wrap_original do |original, **args|
          if Thread.current[:ticket_worker] == :mutation && args[:action] == audit_action && !Thread.current[:paused_audit]
            Thread.current[:paused_audit] = true
            audit_ready << true
            Timeout.timeout(8) { release_audit.pop }
          end
          original.call(**args)
        end
        workers = [worker(:mutation, outcomes, connections) do
          client = ActionDispatch::Integration::Session.new(Rails.application)
          case mutation
          when :rotate
            client.post "/api/v1/orders/#{@order.id}/tickets/#{@ticket.id}/rotate_scan", headers: @buyer_headers
          when :create
            client.post "/api/v1/orders/#{@order.id}/tickets/#{@ticket.id}/transfer",
              params: { recipient_email: @recipient.email }, headers: @buyer_headers
          when :accept
            client.post "/api/v1/me/ticket_transfers/accept", params: { token: token }, headers: @recipient_headers
          when :direct
            client.post "/api/v1/check_in/#{old_scan}", headers: @direct_headers
          when :cancel
            client.delete "/api/v1/me/tickets/#{@ticket.id}/transfer", headers: @buyer_headers
          when :expire
            ExpireInventoryHoldsJob.perform_now
            next [200, {}]
          when :free_cancel
            client.post "/api/v1/orders/#{@order.id}/tickets/#{@ticket.id}/cancel", headers: @buyer_headers
          when :guest
            client.post "/api/v1/me/orders/recover_guest", headers: @buyer_headers
          when :seat
            client.post "/api/v1/orders/#{@order.id}/tickets/#{@ticket.id}/exchange_seat",
              params: { event_seat_id: target_seat.id }, headers: @buyer_headers
          when :lifecycle
            Commerce::OrderLifecycle.cancel!(Order.find(pending_order.id))
            next [200, {}]
          end
          [client.response.status, client.response.parsed_body]
        end]
        mutation_pid = connections.pop.last
        Timeout.timeout(8) { audit_ready.pop } # Real lower locks held, immediately before the audit INSERT.
        workers << worker(:admission, outcomes, connections) { admission_request(operation) }
        admission_pid = connections.pop.last
        expect(admission_pid).not_to eq(mutation_pid)
        await { blocked_by?(admission_pid, mutation_pid) }
        # Old code waits for ORDER/TICKET (or EVENT for lifecycle) while owning
        # ORG FOR UPDATE. Resuming the real audit FK closes the old cycle.
        # Fixed code waits for the mutation's compatible parent prefix instead.
        release_audit << true
        Timeout.timeout(12) { workers.each(&:join) }
        results = 2.times.map { outcomes.pop }.to_h
        expect(results.values.grep(Exception)).to be_empty,
          results.transform_values { |value| value.is_a?(Exception) ? "#{value.class}: #{value.message}" : value }.inspect
        expect(results.fetch(:mutation).first).to eq(mutation == :create ? 201 : 200)
        expect(results.fetch(:admission).first).to eq(200)
        expected = case mutation
        when :rotate, :accept, :free_cancel, :seat then ["rejected", "credential_revoked"]
        when :direct then ["conflict", "already_admitted"]
        else ["accepted", "admitted"]
        end
        expect(results.fetch(:admission).last.fetch("results")).to match([include(
          "action_uuid" => @input[:action_uuid], "sequence" => 1, "result" => expected.first, "reason_code" => expected.last)])
        action = AdmissionAction.find_by!(action_uuid: @input[:action_uuid])
        expect(AdmissionAction.where(scanner_device: @device).count).to eq(1)
        expect(action).to have_attributes(sequence: 1, ticket_id: @ticket.id)
        expect(@device.reload.last_sequence).to eq(1)
        expect(AuditLog.where(auditable: action, action: "ticket.admission_reconciled").count).to eq(1)
        expect(AuditWriteFailure.count).to eq(0), AuditWriteFailure.pluck(:action, :failure_class).inspect
        if operation == :recover
          expect(AuditLog.find_by!(auditable: @device, action: "scanner_device.journal_recovered").metadata)
            .to include("action_uuids" => [@input[:action_uuid]], "original_user_id" => @staff.id)
        end
        @ticket.reload
        if %i[rotate accept seat].include?(mutation)
          expect(@ticket).to be_issued
          expect(@ticket.first_admitted_at).to be_nil
          expect(TicketCredential.find_scan(old_scan)).to be_nil
          expect(@ticket.scan_credential_version).to eq(old_version + 1)
          rotated = AuditLog.where(auditable: @ticket, action: "ticket.scan_credential_rotated").sole
          expect(rotated.actor_user_id).to eq(mutation == :accept ? @recipient.id : @buyer.id)
          if mutation == :accept
            expect(@ticket.holder_user_id).to eq(@recipient.id)
            expect(TicketCredential.find_display(old_display)).to be_nil
            expect(TicketTransferCredential.find(token)).to be_nil
            expect(transfer.reload).to be_accepted
            expect(AuditLog.where(auditable: transfer, action: "ticket_transfer.accepted").sole.actor_user_id).to eq(@recipient.id)
          else
            expect(@ticket.holder_user_id).to eq(@buyer.id)
            if mutation == :seat
              expect(TicketCredential.find_display(old_display)).to be_nil
              expect(@ticket.event_seat_id).to eq(target_seat.id)
              expect(original_seat.reload).to be_selectable
              expect(SeatAuditEvent.where(ticket: @ticket, action: "seat.exchanged").count).to eq(1)
            else
              expect(TicketCredential.find_display(old_display)).to eq(@ticket)
            end
          end
        elsif mutation == :free_cancel
          expect(@ticket).to be_cancelled
          expect(@type.reload.quantity_sold).to eq(0)
          expect(@ticket.first_admitted_at).to be_nil
        else
          expect(@ticket).to be_checked_in
          expect(@ticket.first_admitted_at).to be_present
          expect(@type.reload.quantity_sold).to eq(1)
          expect(@ticket.scan_credential).to eq(old_scan)
          expect(@ticket.holder_user_id).to eq(@buyer.id)
          expect(transfer.reload.status).to eq(mutation == :cancel ? "cancelled" : "expired") if transfer
          if mutation == :create
            created = @ticket.ticket_transfers.pending.sole
            expect(AuditLog.where(auditable: created, action: "ticket_transfer.created").sole.actor_user_id).to eq(@buyer.id)
            expect { TicketTransfers::Manager.accept!(token: TicketTransferCredential.issue(created), user: @recipient) }
              .to raise_error(TicketTransfers::Manager::TransferError, /unused active/)
            expect(created.reload).to be_pending
          end
          expect(pending_order.reload).to be_cancelled if pending_order
        end
        expect(AuditLog.where(action: audit_action).count).to eq(1)
        expect_original_evidence
        # Stable replay may not consume another sequence or recreate an admission.
        first_admission = @ticket.first_admitted_at
        expect(admission_request(operation).first).to eq(200)
        expect(AdmissionAction.where(scanner_device: @device).count).to eq(1)
        expect(@ticket.reload.first_admitted_at).to eq(first_admission)
      ensure
        workers&.each { |thread| thread.kill if thread.alive? }
        workers&.each(&:join)
      end
    end
  end

  %i[sync recover].each do |operation|
    %i[rotate create accept].each do |mutation|
      it "refuses #{mutation} after waiting for #{operation}'s committed admission" do
        transfer = TicketTransfers::Manager.create!(ticket: @ticket, recipient_email: @recipient.email,
          initiated_by: @buyer) if mutation == :accept
        token = TicketTransferCredential.issue(transfer) if transfer
        prepare_manifest
        credential = @ticket.scan_credential
        version = @ticket.scan_credential_version
        ticket_ready, release_ticket = Queue.new, Queue.new
        outcomes, connections = Queue.new, Queue.new
        allow_any_instance_of(Ticket).to receive(:lock!).and_wrap_original do |original, *args|
          result = original.call(*args)
          if Thread.current[:ticket_worker] == :admission && !Thread.current[:paused_ticket]
            Thread.current[:paused_ticket] = true
            ticket_ready << true
            Timeout.timeout(8) { release_ticket.pop }
          end
          result
        end
        workers = [worker(:admission, outcomes, connections) { admission_request(operation) }]
        admission_pid = connections.pop.last
        Timeout.timeout(8) { ticket_ready.pop }
        workers << worker(:mutation, outcomes, connections) do
          client = ActionDispatch::Integration::Session.new(Rails.application)
          if mutation == :accept
            client.post "/api/v1/me/ticket_transfers/accept", params: { token: token }, headers: @recipient_headers
          elsif mutation == :create
            client.post "/api/v1/orders/#{@order.id}/tickets/#{@ticket.id}/transfer",
              params: { recipient_email: @recipient.email }, headers: @buyer_headers
          else
            client.post "/api/v1/orders/#{@order.id}/tickets/#{@ticket.id}/rotate_scan", headers: @buyer_headers
          end
          [client.response.status, client.response.parsed_body]
        end
        mutation_pid = connections.pop.last
        expect(mutation_pid).not_to eq(admission_pid)
        await { blocked_by?(mutation_pid, admission_pid) }
        release_ticket << true
        Timeout.timeout(12) { workers.each(&:join) }
        results = 2.times.map { outcomes.pop }.to_h
        expect(results.values.grep(Exception)).to be_empty, results.inspect
        expect(results.fetch(:admission)).to match([200, include("results" => [include("result" => "accepted")])])
        expect(results.fetch(:mutation).first).to eq(422)
        expect(@ticket.reload).to have_attributes(status: "checked_in", scan_credential_version: version)
        expect(@ticket.scan_credential).to eq(credential)
        expect(@ticket.holder_user_id).to eq(@buyer.id)
        expect(AdmissionAction.where(action_uuid: @input[:action_uuid]).count).to eq(1)
        expect(@device.reload.last_sequence).to eq(1)
        expect(transfer.reload).to be_pending if transfer
        expect(AuditLog.where(auditable: @ticket, action: "ticket.scan_credential_rotated")).to be_empty
        expect(AuditWriteFailure.count).to eq(0), AuditWriteFailure.pluck(:action, :failure_class).inspect
        expect_original_evidence
      ensure
        workers&.each { |thread| thread.kill if thread.alive? }
        workers&.each(&:join)
      end
    end
  end

  %i[rotate create free_cancel].each do |mutation|
    it "rechecks the current holder after #{mutation}'s buyer preflight becomes stale" do
      transfer = TicketTransfers::Manager.create!(ticket: @ticket, recipient_email: @recipient.email, initiated_by: @buyer)
      token = TicketTransferCredential.issue(transfer)
      preflight, release = Queue.new, Queue.new
      outcomes, connections = Queue.new, Queue.new
      allow_any_instance_of(Api::V1::OrdersController).to receive(:controls_ticket?).and_wrap_original do |original, *args|
        result = original.call(*args)
        if Thread.current[:ticket_worker] == :stale && !Thread.current[:paused_preflight]
          Thread.current[:paused_preflight] = true
          preflight << true
          Timeout.timeout(8) { release.pop }
        end
        result
      end
      workers = [worker(:stale, outcomes, connections) do
        client = ActionDispatch::Integration::Session.new(Rails.application)
        suffix = { rotate: "rotate_scan", create: "transfer", free_cancel: "cancel" }.fetch(mutation)
        client.post "/api/v1/orders/#{@order.id}/tickets/#{@ticket.id}/#{suffix}",
          params: { recipient_email: "next@example.com" }, headers: @buyer_headers
        [client.response.status, client.response.parsed_body]
      end]
      Timeout.timeout(8) { preflight.pop }
      TicketTransfers::Manager.accept!(token: token, user: @recipient)
      accepted_version = @ticket.reload.scan_credential_version
      accepted_credential = @ticket.scan_credential
      release << true
      Timeout.timeout(12) { workers.each(&:join) }
      result = outcomes.pop.last
      expect(result).not_to be_a(Exception)
      expect(result.first).to eq(422)
      expect(@ticket.reload).to have_attributes(status: "issued", holder_user_id: @recipient.id,
        scan_credential_version: accepted_version)
      expect(@ticket.scan_credential).to eq(accepted_credential)
      expect(@ticket.ticket_transfers.pending.count).to eq(0)
      expect(@type.reload.quantity_sold).to eq(1)
      expect(AuditLog.where(auditable: @ticket, action: "ticket.scan_credential_rotated").count).to eq(1)
      expect(AuditWriteFailure.count).to eq(0), AuditWriteFailure.pluck(:action, :failure_class).inspect
    ensure
      workers&.each { |thread| thread.kill if thread.alive? }
      workers&.each(&:join)
    end
  end

  it "rechecks a resolved direct check-in credential after a real buyer rotation commits" do
    old_scan = @ticket.scan_credential
    resolved, release = Queue.new, Queue.new
    outcomes, connections = Queue.new, Queue.new
    allow(TicketCredential).to receive(:find_scan).and_wrap_original do |original, *args|
      result = original.call(*args)
      if Thread.current[:ticket_worker] == :direct
        resolved << true
        Timeout.timeout(8) { release.pop }
      end
      result
    end
    workers = [worker(:direct, outcomes, connections) do
      client = ActionDispatch::Integration::Session.new(Rails.application)
      client.post "/api/v1/check_in/#{old_scan}", headers: @direct_headers
      [client.response.status, client.response.parsed_body]
    end]
    Timeout.timeout(8) { resolved.pop }
    post "/api/v1/orders/#{@order.id}/tickets/#{@ticket.id}/rotate_scan", headers: @buyer_headers
    expect(response).to have_http_status(:ok)
    release << true
    Timeout.timeout(12) { workers.each(&:join) }
    result = outcomes.pop.last
    expect(result).to match([422, include("error" => "Ticket credential has been replaced")])
    expect(@ticket.reload).to be_issued
    expect(@ticket.first_admitted_at).to be_nil
    expect(AuditLog.where(auditable: @ticket, action: "ticket.checked_in")).to be_empty
    expect(AuditWriteFailure.count).to eq(0), AuditWriteFailure.pluck(:action, :failure_class).inspect
  ensure
    workers&.each { |thread| thread.kill if thread.alive? }
    workers&.each(&:join)
  end

  %i[same different].each do |recipient|
    it "serializes #{recipient}-recipient create retries with one pending transfer and one audit" do
      ready, release = Queue.new, Queue.new
      outcomes, connections = Queue.new, Queue.new
      pause_audit("ticket_transfer.created", ready, release)
      workers = [worker(:first, outcomes, connections) { create_transfer_request(@recipient.email) }]
      first_pid = connections.pop.last
      Timeout.timeout(8) { ready.pop }
      workers << worker(:second, outcomes, connections) do
        create_transfer_request(recipient == :same ? @recipient.email : "other@example.com")
      end
      second_pid = connections.pop.last
      expect(first_pid).not_to eq(second_pid)
      await { blocked_by?(second_pid, first_pid) }
      release << true
      Timeout.timeout(12) { workers.each(&:join) }
      results = 2.times.map { outcomes.pop }.to_h
      expect(results.fetch(:first).first).to eq(201)
      expect(results.fetch(:second).first).to eq(recipient == :same ? 201 : 422)
      pending = @ticket.ticket_transfers.pending.sole
      expect(AuditLog.where(auditable: pending, action: "ticket_transfer.created").count).to eq(1)
      expect(AuditWriteFailure.count).to eq(0), AuditWriteFailure.pluck(:action, :failure_class).inspect
    ensure
      workers&.each { |thread| thread.kill if thread.alive? }
      workers&.each(&:join)
    end
  end

  it "accepts a raced transfer token only once and never reuses either credential" do
    transfer = TicketTransfers::Manager.create!(ticket: @ticket, recipient_email: @recipient.email, initiated_by: @buyer)
    token = TicketTransferCredential.issue(transfer)
    old_scan, old_display = @ticket.scan_credential, @ticket.display_credential
    old_version = @ticket.scan_credential_version
    ready, release = Queue.new, Queue.new
    outcomes, connections = Queue.new, Queue.new
    pause_audit("ticket.scan_credential_rotated", ready, release)
    accept = lambda do
      client = ActionDispatch::Integration::Session.new(Rails.application)
      client.post "/api/v1/me/ticket_transfers/accept", params: { token: token }, headers: @recipient_headers
      [client.response.status, client.response.parsed_body]
    end
    workers = [worker(:first, outcomes, connections, &accept)]
    first_pid = connections.pop.last
    Timeout.timeout(8) { ready.pop }
    workers << worker(:second, outcomes, connections, &accept)
    second_pid = connections.pop.last
    expect(first_pid).not_to eq(second_pid)
    await { blocked_by?(second_pid, first_pid) }
    release << true
    Timeout.timeout(12) { workers.each(&:join) }
    results = 2.times.map { outcomes.pop }.to_h
    expect(results.fetch(:first).first).to eq(200)
    expect(results.fetch(:second).first).to eq(422)
    expect(@ticket.reload).to have_attributes(holder_user_id: @recipient.id, scan_credential_version: old_version + 1)
    expect(TicketCredential.find_scan(old_scan)).to be_nil
    expect(TicketCredential.find_display(old_display)).to be_nil
    expect(TicketTransferCredential.find(token)).to be_nil
    expect(AuditLog.where(auditable: transfer, action: "ticket_transfer.accepted").count).to eq(1)
    expect(AuditLog.where(auditable: @ticket, action: "ticket.scan_credential_rotated").count).to eq(1)
    expect(AuditWriteFailure.count).to eq(0), AuditWriteFailure.pluck(:action, :failure_class).inspect
  ensure
    workers&.each { |thread| thread.kill if thread.alive? }
    workers&.each(&:join)
  end

  it "rolls back the entire recovery when its required audit fails, then permits an exact retry" do
    prepare_manifest
    allow(AuditLogger).to receive(:write!).and_wrap_original do |original, **args|
      raise AuditLogger::WriteError, "required recovery audit unavailable" if args[:action] == "scanner_device.journal_recovered"

      original.call(**args)
    end
    expect do
      Admissions::JournalRecovery.call(device: @device, actor: @staff, actions: [@input],
        reason: @params[:reason], window_start: @params[:window_start], window_end: @params[:window_end])
    end.to raise_error(AuditLogger::WriteError, /required recovery audit/)
    expect(@ticket.reload).to be_issued
    expect(@ticket.first_admitted_at).to be_nil
    expect(@device.reload.last_sequence).to eq(0)
    expect(AdmissionAction.where(scanner_device: @device)).to be_empty
    expect(AuditLog.where(action: "ticket.admission_reconciled")).to be_empty
    expect(AuditWriteFailure.count).to eq(0), AuditWriteFailure.pluck(:action, :failure_class).inspect
    expect_original_evidence
    allow(AuditLogger).to receive(:write!).and_call_original
    expect(admission_request(:recover).first).to eq(200)
    expect(@ticket.reload).to be_checked_in
    expect(AdmissionAction.where(action_uuid: @input[:action_uuid]).count).to eq(1)
    expect(@device.reload.last_sequence).to eq(1)
    expect_original_evidence
  end

  %i[cancel expire].each do |ending|
    %i[create accept].each do |next_mutation|
      it "serializes transfer #{ending} with #{next_mutation} without a transfer-to-parent inversion" do
        transfer = TicketTransfers::Manager.create!(ticket: @ticket, recipient_email: @recipient.email, initiated_by: @buyer)
        token = TicketTransferCredential.issue(transfer)
        transfer.update_columns(expires_at: 1.minute.ago) if ending == :expire
        ready, release = Queue.new, Queue.new
        outcomes, connections = Queue.new, Queue.new
        pause_audit("ticket_transfer.#{ending == :cancel ? 'cancelled' : 'expired'}", ready, release)
        old_version = @ticket.scan_credential_version
        workers = [worker(:first, outcomes, connections) do
          if ending == :expire
            ExpireInventoryHoldsJob.perform_now
            [200, {}]
          else
            client = ActionDispatch::Integration::Session.new(Rails.application)
            client.delete "/api/v1/me/tickets/#{@ticket.id}/transfer", headers: @buyer_headers
            [client.response.status, client.response.parsed_body]
          end
        end]
        first_pid = connections.pop.last
        Timeout.timeout(8) { ready.pop }
        workers << worker(:second, outcomes, connections) do
          if next_mutation == :create
            create_transfer_request("next@example.com")
          else
            client = ActionDispatch::Integration::Session.new(Rails.application)
            client.post "/api/v1/me/ticket_transfers/accept", params: { token: token }, headers: @recipient_headers
            [client.response.status, client.response.parsed_body]
          end
        end
        second_pid = connections.pop.last
        expect(first_pid).not_to eq(second_pid)
        await { blocked_by?(second_pid, first_pid) }
        release << true
        Timeout.timeout(12) { workers.each(&:join) }
        results = 2.times.map { outcomes.pop }.to_h
        expect(results.values.grep(Exception)).to be_empty, results.inspect
        expect(results.fetch(:first).first).to eq(200)
        expect(results.fetch(:second).first).to eq(next_mutation == :create ? 201 : 422)
        expect(transfer.reload.status).to eq(ending == :cancel ? "cancelled" : "expired")
        expect(TicketTransferCredential.find(token)).to be_nil
        expect(@ticket.reload).to have_attributes(status: "issued", holder_user_id: @buyer.id, scan_credential_version: old_version)
        expect(@ticket.ticket_transfers.pending.count).to eq(next_mutation == :create ? 1 : 0)
        expect(AuditWriteFailure.count).to eq(0), AuditWriteFailure.pluck(:action, :failure_class).inspect
      ensure
        workers&.each { |thread| thread.kill if thread.alive? }
        workers&.each(&:join)
      end
    end
  end

  %i[rotate guest].each do |mutation|
    it "allows event-first commerce's organization audit FK while #{mutation} waits for EVENT" do
      if mutation == :guest
        @order.update!(user: nil)
        @ticket.update!(holder_user: nil)
      end
      pending = create(:order, :pending, event: @event)
      ready, release = Queue.new, Queue.new
      outcomes, connections = Queue.new, Queue.new
      pause_audit("order.cancelled", ready, release)
      workers = [worker(:first, outcomes, connections) do
        Commerce::OrderLifecycle.cancel!(Order.find(pending.id))
        [200, {}]
      end]
      first_pid = connections.pop.last
      Timeout.timeout(8) { ready.pop }
      workers << worker(:second, outcomes, connections) do
        client = ActionDispatch::Integration::Session.new(Rails.application)
        path = mutation == :rotate ? "/api/v1/orders/#{@order.id}/tickets/#{@ticket.id}/rotate_scan" : "/api/v1/me/orders/recover_guest"
        client.post path, headers: @buyer_headers
        [client.response.status, client.response.parsed_body]
      end
      second_pid = connections.pop.last
      expect(first_pid).not_to eq(second_pid)
      await { blocked_by?(second_pid, first_pid) }
      release << true
      Timeout.timeout(12) { workers.each(&:join) }
      results = 2.times.map { outcomes.pop }.to_h
      expect(results.values.grep(Exception)).to be_empty, results.inspect
      expect(results.fetch(:first).first).to eq(200)
      expect(results.fetch(:second).first).to eq(200)
      expect(pending.reload).to be_cancelled
      expect(@ticket.reload).to be_issued
      expect(@ticket.holder_user_id).to eq(@buyer.id)
      expect(@type.reload.quantity_sold).to eq(1)
      expect(AuditLog.where(auditable: pending, action: "order.cancelled").count).to eq(1)
      expect(AuditWriteFailure.count).to eq(0), AuditWriteFailure.pluck(:action, :failure_class).inspect
    ensure
      workers&.each { |thread| thread.kill if thread.alive? }
      workers&.each(&:join)
    end
  end

  %i[manifest renewal].each do |operation|
    it "allows scanner #{operation} versus event-first lifecycle audit FK without a lock cycle" do
      pending = create(:order, :pending, event: @event)
      ready, release = Queue.new, Queue.new
      outcomes, connections = Queue.new, Queue.new
      pause_audit("order.cancelled", ready, release)
      workers = [worker(:first, outcomes, connections) do
        Commerce::OrderLifecycle.cancel!(Order.find(pending.id))
        [200, {}]
      end]
      first_pid = connections.pop.last
      Timeout.timeout(8) { ready.pop }
      workers << worker(:second, outcomes, connections) do
        client = ActionDispatch::Integration::Session.new(Rails.application)
        if operation == :manifest
          client.get "#{@base}/manifest", headers: @headers
        else
          client.post "/api/v1/organizer/events/#{@event.id}/scanner_devices",
            params: { identifier: @device.identifier, name: "Renewed gate" }, headers: @headers
        end
        [client.response.status, client.response.parsed_body]
      end
      second_pid = connections.pop.last
      expect(first_pid).not_to eq(second_pid)
      await { blocked_by?(second_pid, first_pid) }
      release << true
      Timeout.timeout(12) { workers.each(&:join) }
      results = 2.times.map { outcomes.pop }.to_h
      expect(results.values.grep(Exception)).to be_empty, results.transform_values { |v| v.is_a?(Exception) ? "#{v.class}: #{v.message}" : v.first }.inspect
      expect(results.fetch(:first).first).to eq(200)
      expect(results.fetch(:second).first).to eq(operation == :manifest ? 200 : 201)
      expect(AuditWriteFailure.count).to eq(0), AuditWriteFailure.pluck(:action, :failure_class).inspect
      expect(AuditLog.where(auditable: pending, action: "order.cancelled").count).to eq(1)
    ensure
      workers&.each { |thread| thread.kill if thread.alive? }
      workers&.each(&:join)
    end
  end

  def create_transfer_request(email)
    client = ActionDispatch::Integration::Session.new(Rails.application)
    client.post "/api/v1/orders/#{@order.id}/tickets/#{@ticket.id}/transfer",
      params: { recipient_email: email }, headers: @buyer_headers
    [client.response.status, client.response.parsed_body]
  end

  def pause_audit(action, ready, release)
    allow(AuditLogger).to receive(:write!).and_wrap_original do |original, **args|
      if Thread.current[:ticket_worker] == :first && args[:action] == action && !Thread.current[:paused_audit]
        Thread.current[:paused_audit] = true
        ready << true
        Timeout.timeout(8) { release.pop }
      end
      original.call(**args)
    end
  end

  def prepare_manifest
    get "#{@base}/manifest", headers: @headers
    expect(response).to have_http_status(:ok)
    @manifest = AdmissionManifest.find_by!(event: @event, version: response.parsed_body.dig("payload", "version"))
    @payload = @manifest.payload.deep_dup
    @digest = @manifest.digest
    @download = AuditLog.where(auditable: @device, action: "scanner_device.manifest_downloaded").sole
    @evidence = @download.after_data.deep_dup
    @lease = @device.reload.authorization_expires_at
    @input = { action_uuid: "aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee", sequence: 1, kind: "admit", source: "offline", ticket_id: @ticket.id,
      credential_hash: Digest::SHA256.hexdigest(@ticket.scan_credential), manifest_version: @manifest.version,
      occurred_at: Time.current.iso8601(6) }
    @params = { actions: [@input], reason: "Independently checked original gate journal",
      window_start: @evidence.fetch("downloaded_at"), window_end: Time.current.iso8601(6) }
  end

  def admission_request(operation)
    client = ActionDispatch::Integration::Session.new(Rails.application)
    client.post "#{@base}/#{operation}", params: @params, headers: @headers
    [client.response.status, client.response.parsed_body]
  end

  def expect_original_evidence
    expect(@manifest.reload).to have_attributes(payload: @payload, digest: @digest)
    expect(@download.reload.after_data).to eq(@evidence)
    expect(@device.reload.authorization_expires_at).to eq(@lease)
    expect(AuditLog.where(auditable: @device, action: "scanner_device.manifest_downloaded").count).to eq(1)
  end

  def worker(name, outcomes, connections)
    Thread.new do
      Thread.current[:ticket_worker] = name
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

  def blocked_by?(waiting, holding)
    ActiveRecord::Base.connection.select_value("SELECT #{Integer(holding)} = ANY(pg_blocking_pids(#{Integer(waiting)}))")
  end

  def await
    Timeout.timeout(6) do
      loop do
        break if yield

        sleep 0.01
      end
    end
  end

  def clean_data
    ActiveRecord::Base.connection.execute("TRUNCATE TABLE audit_logs, audit_write_failures, users, organizer_profiles, events, venues, site_settings, webhook_events RESTART IDENTITY CASCADE")
  end
end
