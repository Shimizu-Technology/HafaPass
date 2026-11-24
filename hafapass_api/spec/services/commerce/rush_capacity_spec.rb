# frozen_string_literal: true

require "rails_helper"
require "timeout"

# Sales-open rush: shortened checkout critical section, the pre-lock sold-out
# refusal, and the nested completion that reuses checkout's event locks.
RSpec.describe "Commerce rush capacity", :non_transactional do
  self.use_transactional_tests = false

  before do
    raise "Concurrency specs must only run in test" unless Rails.env.test?

    clean_test_data
    allow(StripeService).to receive(:payment_enabled?).and_return(true)
    allow(StripeService).to receive(:create_payment_intent) do |order, idempotency_key:, **_context|
      OpenStruct.new(id: "pi_rush_#{order.id}", client_secret: "#{idempotency_key}_secret",
        allowed_payment_method_types: ["card"], payment_method_types: ["card"])
    end
  end

  after { clean_test_data }

  def public_checkout(event, ticket_type, index, quantity: 1, **options)
    Commerce::OrderCreator.call(
      event: Event.find(event.id),
      line_items: [{ ticket_type_id: ticket_type.id, quantity: quantity }],
      buyer_email: "rush-#{index}@example.invalid",
      buyer_name: "Rush Buyer #{index}",
      enforce_buyer_limits: true,
      checkout_ip_digest: Digest::SHA256.hexdigest("shared-nat"),
      **options
    )
  end

  it "sells exactly the remaining free tickets to parallel public buyers and refuses the rest cleanly" do
    event = create(:event, :published, starts_at: 5.days.from_now, max_capacity: 2)
    ticket_type = create(:ticket_type, :free, event: event, quantity_available: 2, max_per_order: 1)

    outcomes = run_concurrently(4) { |index| public_checkout(event, ticket_type, index) }

    expect(outcomes.grep(Commerce::OrderCreator::Result).size).to eq(2)
    refusals = outcomes.grep(Commerce::OrderCreator::CheckoutError)
    expect(refusals.size).to eq(2)
    expect(refusals.map(&:message)).to all(match(/Only 0 (tickets available|tickets remain)/))
    expect(ticket_type.reload.quantity_sold).to eq(2)
    expect(Ticket.where(event: event).where.not(status: :cancelled).count).to eq(2)
    expect(InventoryHold.current.where(event: event).sum(:quantity)).to eq(0)
  end

  it "never oversells shared night capacity between parallel pass and single-night buyers" do
    owner = create(:user)
    profile = create(:organizer_profile, user: owner)
    org = profile.organization
    pass_event = create(:event, :published, organizer_profile: profile, organization: org, title: "Rush Pass",
      max_capacity: 50, starts_at: 2.days.from_now, ends_at: 10.days.from_now)
    night_a = create(:event, :published, organizer_profile: profile, organization: org, title: "Rush Night 1",
      max_capacity: 2, starts_at: 2.days.from_now, ends_at: 2.days.from_now + 3.hours)
    night_b = create(:event, :published, organizer_profile: profile, organization: org, title: "Rush Night 2",
      max_capacity: 2, starts_at: 3.days.from_now, ends_at: 3.days.from_now + 3.hours)
    pass_tt = create(:ticket_type, :free, event: pass_event, name: "Rush Pass", quantity_available: 50, max_per_order: 1)
    TicketTypeIncludedEvent.create!(ticket_type: pass_tt, included_event: night_a, position: 0)
    TicketTypeIncludedEvent.create!(ticket_type: pass_tt, included_event: night_b, position: 1)
    night_tt = create(:ticket_type, :free, event: night_a, name: "Night 1 GA", quantity_available: 50, max_per_order: 1)

    outcomes = run_concurrently(4) do |index|
      index.even? ? public_checkout(pass_event, pass_tt, index) : public_checkout(night_a, night_tt, index)
    end

    successes = outcomes.grep(Commerce::OrderCreator::Result)
    expect(outcomes - successes).to all(be_a(Commerce::OrderCreator::CheckoutError))
    expect(successes.size).to eq(2)
    expect(Ticket.where(event: night_a).where.not(status: :cancelled).count).to eq(2)
    expect(EventCapacity.remaining_for(night_a)).to eq(0)
    # A pass is all-or-nothing: each issued parent has one ticket per night.
    Ticket.where(ticket_type: pass_tt, parent_ticket_id: nil).find_each do |parent|
      expect(Ticket.where(parent_ticket_id: parent.id).pluck(:event_id)).to contain_exactly(night_a.id, night_b.id)
    end
  end

  it "refuses a sold-out public checkout without waiting for the event lock" do
    event = create(:event, :published, starts_at: 5.days.from_now)
    ticket_type = create(:ticket_type, :free, event: event, quantity_available: 1, max_per_order: 1)
    public_checkout(event, ticket_type, 0)

    locked = Queue.new
    release = Queue.new
    holder = Thread.new do
      ActiveRecord::Base.connection_pool.with_connection do
        Event.transaction do
          Event.lock("FOR NO KEY UPDATE").find(event.id)
          locked << true
          Timeout.timeout(10) { release.pop }
        end
      end
    end
    Timeout.timeout(5) { locked.pop }

    connection = ActiveRecord::Base.connection
    connection.execute("SET lock_timeout = '1s'")
    expect { public_checkout(event, ticket_type, 1) }
      .to raise_error(Commerce::OrderCreator::CheckoutError, "Only 0 tickets available for #{ticket_type.name}")
  ensure
    connection&.execute("SET lock_timeout = 0")
    release&.push(true)
    holder&.join
  end

  it "still returns the original order to a same-key retry after the event sells out" do
    SiteSetting.instance.update!(payment_mode: "test")
    allow(StripeService).to receive(:publishable_key).and_return("pk_test_rush")
    allow(StripeService).to receive(:retrieve_payment_intent) do |payment|
      OpenStruct.new(id: payment.provider_payment_id, amount: payment.amount_cents, currency: payment.currency,
        status: "requires_payment_method", livemode: false, client_secret: "original_secret",
        allowed_payment_method_types: ["card"], payment_method_types: ["card"])
    end
    event = create(:event, :published, starts_at: 5.days.from_now)
    ticket_type = create(:ticket_type, event: event, price_cents: 2500, quantity_available: 1, max_per_order: 1)
    digest = Digest::SHA256.hexdigest(SecureRandom.hex(32))
    first = public_checkout(event, ticket_type, 0, checkout_key_digest: digest, checkout_request_digest: "c" * 64)
    expect(ticket_type.reload.available_quantity).to eq(0)

    retry_result = public_checkout(event, ticket_type, 0, checkout_key_digest: digest, checkout_request_digest: "c" * 64)

    expect(retry_result.order.id).to eq(first.order.id)
    expect(InventoryHold.current.where(event: event).sum(:quantity)).to eq(1)
  end

  describe "inventory coming back after a sell-out" do
    it "sells a refunded ticket to the next public buyer at once" do
      allow(EmailService).to receive(:send_refund_notification_async)
      allow(StripeService).to receive(:refund_payment) do |_payment, amount_cents:, **|
        OpenStruct.new(id: "re_rush_refund", status: "succeeded", amount: amount_cents, currency: "usd")
      end
      event = create(:event, :published, starts_at: 5.days.from_now)
      ticket_type = create(:ticket_type, event: event, price_cents: 1000, quantity_available: 1, quantity_sold: 1, max_per_order: 1)
      order = create(:order, event: event, buyer_email: "refunded@example.invalid")
      item = create(:order_item, order: order, ticket_type: ticket_type, quantity: 1, unit_price_cents: 1000, fee_cents: 0)
      ticket = create(:ticket, event: event, order: order, order_item: item, ticket_type: ticket_type)
      create(:payment, :succeeded, order: order, provider_environment: "live", amount_cents: order.total_cents)
      expect { public_checkout(event, ticket_type, 1) }
        .to raise_error(Commerce::OrderCreator::CheckoutError, "Only 0 tickets available for #{ticket_type.name}")

      expect do
        Commerce::RefundCreator.call(order: order.reload, tickets: [ticket], reason: "rush spec",
          requested_by: event.organizer_profile.user, organizer_initiated: true)
      end.to change { PublicEventCache.generation }.by(1)
      expect(ticket.reload).to be_cancelled
      expect(ticket_type.reload.available_quantity).to eq(1)

      result = public_checkout(event, ticket_type, 2)
      expect(result.order).to be_pending
      expect(InventoryHold.current.where(order: result.order).sum(:quantity)).to eq(1)
      expect(ticket_type.reload.available_quantity).to eq(0)
    end

    it "sells a lapsed hold's ticket before ExpireInventoryHoldsJob releases it" do
      event = create(:event, :published, starts_at: 5.days.from_now)
      ticket_type = create(:ticket_type, event: event, price_cents: 2500, quantity_available: 1, max_per_order: 1)
      held = public_checkout(event, ticket_type, 0)
      expect(held.order).to be_pending
      expect { public_checkout(event, ticket_type, 1) }
        .to raise_error(Commerce::OrderCreator::CheckoutError, "Only 0 tickets available for #{ticket_type.name}")

      # The hold's time runs out; the expiry job has not run, so its row is
      # still active.
      InventoryHold.where(order: held.order).update_all(expires_at: 1.second.ago)
      held.order.update_columns(expires_at: 1.second.ago)
      expect(InventoryHold.where(order: held.order).pluck(:status)).to all(eq("active"))

      result = public_checkout(event, ticket_type, 2)
      expect(result.order).to be_pending
      expect(result.order.id).not_to eq(held.order.id)
      expect(InventoryHold.current.where(event: event).sum(:quantity)).to eq(1)
    end
  end

  it "refuses a pass when one included night is full, issuing nothing on the open night, and still sells that night" do
    profile = create(:organizer_profile)
    org = profile.organization
    pass_event = create(:event, :published, organizer_profile: profile, organization: org, title: "Partial Pass",
      max_capacity: 50, starts_at: 2.days.from_now, ends_at: 10.days.from_now)
    full_night = create(:event, :published, organizer_profile: profile, organization: org, title: "Full Night",
      max_capacity: 1, starts_at: 2.days.from_now, ends_at: 2.days.from_now + 3.hours)
    open_night = create(:event, :published, organizer_profile: profile, organization: org, title: "Open Night",
      max_capacity: 5, starts_at: 3.days.from_now, ends_at: 3.days.from_now + 3.hours)
    pass_tt = create(:ticket_type, :free, event: pass_event, name: "Partial Pass", quantity_available: 50, max_per_order: 1)
    TicketTypeIncludedEvent.create!(ticket_type: pass_tt, included_event: full_night, position: 0)
    TicketTypeIncludedEvent.create!(ticket_type: pass_tt, included_event: open_night, position: 1)
    full_tt = create(:ticket_type, :free, event: full_night, name: "Full Night GA", quantity_available: 50, max_per_order: 1)
    open_tt = create(:ticket_type, :free, event: open_night, name: "Open Night GA", quantity_available: 50, max_per_order: 1)
    public_checkout(full_night, full_tt, 0)
    expect(EventCapacity.remaining_for(full_night)).to eq(0)
    expect(pass_tt.reload.available_quantity).to be_positive

    expect do
      expect { public_checkout(pass_event, pass_tt, 1) }.to raise_error(Commerce::OrderCreator::CheckoutError)
    end.not_to(change { PublicEventCache.generation })
    expect(Ticket.where(event: open_night).count).to eq(0)
    expect(Ticket.where(ticket_type: pass_tt).count).to eq(0)
    expect(InventoryHold.current.where(event: [pass_event, open_night]).sum(:quantity)).to eq(0)
    expect(EventCapacity.remaining_for(open_night)).to eq(5)

    result = public_checkout(open_night, open_tt, 2)
    expect(result.order.reload).to be_completed
    expect(Ticket.where(event: open_night).where.not(status: :cancelled).count).to eq(1)
  end

  describe "the pre-lock refusal keeps the locked path's error contract" do
    it "reports sales closed, not sold out, for an ended event" do
      event = create(:event, :published, starts_at: 5.days.from_now)
      ticket_type = create(:ticket_type, :free, event: event, quantity_available: 1, quantity_sold: 1, max_per_order: 1)
      event.update_columns(starts_at: 2.days.ago, ends_at: 2.days.ago + 3.hours)

      expect { public_checkout(event, ticket_type, 0) }.to raise_error(Commerce::OrderCreator::SalesClosed)
    end

    it "reports cancelled pass nights, not sold out, for a sold-out pass whose nights were all cancelled" do
      profile = create(:organizer_profile)
      pass_event = create(:event, :published, organizer_profile: profile, organization: profile.organization,
        starts_at: 2.days.from_now, ends_at: 6.days.from_now)
      nights = 2.times.map do |index|
        create(:event, :published, organizer_profile: profile, organization: profile.organization,
          starts_at: (2 + index).days.from_now, ends_at: (2 + index).days.from_now + 3.hours)
      end
      pass_tt = create(:ticket_type, :free, event: pass_event, name: "Pass", quantity_available: 1, max_per_order: 1)
      nights.each_with_index { |night, index| TicketTypeIncludedEvent.create!(ticket_type: pass_tt, included_event: night, position: index) }
      pass_tt.update_columns(quantity_sold: 1)
      Event.where(id: nights.map(&:id)).update_all(status: Event.statuses.fetch("cancelled"))

      expect { public_checkout(pass_event, pass_tt, 0) }
        .to raise_error(Commerce::OrderCreator::CheckoutError, "All included nights for this pass have been cancelled")
    end

    it "reports sales closed, not sold out, while the organizer is unverified" do
      original = ENV["HAFAPASS_ENFORCE_ORGANIZER_VERIFICATION"]
      ENV["HAFAPASS_ENFORCE_ORGANIZER_VERIFICATION"] = "true"
      event = create(:event, :published, starts_at: 5.days.from_now)
      ticket_type = create(:ticket_type, :free, event: event, quantity_available: 1, quantity_sold: 1, max_per_order: 1)
      event.organizer_profile.update_columns(verification_status: OrganizerProfile.verification_statuses.fetch("pending"))
      expect(event.reload.organizer_sales_verified?).to be(false)

      expect { public_checkout(event, ticket_type, 0) }.to raise_error(Commerce::OrderCreator::SalesClosed)
    ensure
      original.nil? ? ENV.delete("HAFAPASS_ENFORCE_ORGANIZER_VERIFICATION") : ENV["HAFAPASS_ENFORCE_ORGANIZER_VERIFICATION"] = original
    end

    it "reports an off-sale ticket type listed before a sold-out one" do
      event = create(:event, :published, starts_at: 5.days.from_now)
      closed = create(:ticket_type, :free, event: event, name: "Early Bird", quantity_available: 5, max_per_order: 1,
        sales_end_at: 1.day.ago)
      sold_out = create(:ticket_type, :free, event: event, name: "GA", quantity_available: 1, quantity_sold: 1, max_per_order: 1)

      expect do
        Commerce::OrderCreator.call(event: Event.find(event.id),
          line_items: [{ ticket_type_id: closed.id, quantity: 1 }, { ticket_type_id: sold_out.id, quantity: 1 }],
          buyer_email: "multi@example.invalid", buyer_name: "Multi Buyer", enforce_buyer_limits: true,
          checkout_ip_digest: Digest::SHA256.hexdigest("shared-nat"))
      end.to raise_error(Commerce::OrderCreator::SalesClosed, /Early Bird is not currently on sale/)
    end
  end

  it "leaves staff sales on the full locked path" do
    event = create(:event, :published, starts_at: 5.days.from_now)
    ticket_type = create(:ticket_type, :free, event: event, quantity_available: 1, max_per_order: 1)
    public_checkout(event, ticket_type, 0)

    statements = []
    callback = ->(*, payload) { statements << payload[:sql] }
    ActiveSupport::Notifications.subscribed(callback, "sql.active_record") do
      expect do
        Commerce::OrderCreator.call(event: Event.find(event.id), line_items: [{ ticket_type_id: ticket_type.id, quantity: 1 }],
          buyer_email: "staff@example.invalid", buyer_name: "Guest List", source: "guest_list")
      end.to raise_error(Commerce::OrderCreator::CheckoutError, /Only 0 tickets available/)
    end
    expect(statements.grep(/FROM "events".*FOR NO KEY UPDATE/)).not_to be_empty
  end

  it "takes each pass event lock once when checkout completes a free pass in the same transaction" do
    profile = create(:organizer_profile)
    pass_event = create(:event, :published, organizer_profile: profile, organization: profile.organization,
      starts_at: 2.days.from_now, ends_at: 6.days.from_now)
    nights = 2.times.map do |index|
      create(:event, :published, organizer_profile: profile, organization: profile.organization,
        starts_at: (2 + index).days.from_now, ends_at: (2 + index).days.from_now + 3.hours, max_capacity: 5)
    end
    pass_tt = create(:ticket_type, :free, event: pass_event, quantity_available: 5, max_per_order: 1)
    nights.each_with_index { |night, index| TicketTypeIncludedEvent.create!(ticket_type: pass_tt, included_event: night, position: index) }

    statements = []
    callback = ->(*, payload) { statements << payload[:sql] }
    result = ActiveSupport::Notifications.subscribed(callback, "sql.active_record") do
      public_checkout(pass_event, pass_tt, 0)
    end

    expect(result.order.reload).to be_completed
    expect(result.order.tickets.where.not(parent_ticket_id: nil).count).to eq(2)
    expect(statements.grep(/FROM "events".*FOR NO KEY UPDATE/).size).to eq(3)
  end

  it "refuses a nested completion flag outside the caller's transaction" do
    order = create(:order, :pending)

    expect { Commerce::OrderLifecycle.complete!(order, event_context_locked: true) }
      .to raise_error(ArgumentError, /open transaction/)
  end

  def run_concurrently(count)
    ready = Queue.new
    start = Queue.new
    results = Queue.new
    threads = count.times.map do |index|
      Thread.new do
        ActiveRecord::Base.connection_pool.with_connection do
          ready << true
          start.pop
          results << yield(index)
        rescue StandardError => e
          results << e
        end
      end
    end
    Timeout.timeout(15) do
      count.times { ready.pop }
      count.times { start << true }
      threads.each(&:join)
      count.times.map { results.pop }
    end
  ensure
    threads&.each { |thread| thread.kill if thread.alive? }
  end

  def clean_test_data
    raise "Isolated test database required" unless ActiveRecord::Base.connection_db_config.database.end_with?("_test")

    connection = ActiveRecord::Base.connection
    connection.execute("SET lock_timeout = '5s'")
    connection.execute(<<~SQL)
      TRUNCATE TABLE audit_logs, audit_write_failures, users, organizer_profiles, events, site_settings, webhook_events,
        checkout_attempts, public_cache_generations
      RESTART IDENTITY CASCADE
    SQL
  ensure
    connection&.execute("SET lock_timeout = 0")
  end
end
