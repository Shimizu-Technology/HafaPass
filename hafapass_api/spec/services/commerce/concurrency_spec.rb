require "rails_helper"
require "timeout"

RSpec.describe "Commerce concurrency", :non_transactional do
  self.use_transactional_tests = false

  before do
    raise "Concurrency specs must only run in test" unless Rails.env.test?

    clean_test_data
    allow(StripeService).to receive(:payment_enabled?).and_return(true)
    allow(StripeService).to receive(:create_payment_intent) do |order, idempotency_key:, **_context|
      OpenStruct.new(id: "pi_concurrent_#{order.id}", client_secret: "#{idempotency_key}_secret",
        allowed_payment_method_types: ["card"], payment_method_types: ["card"])
    end
    allow(EmailService).to receive(:send_refund_notification_async)
  end

  after do
    clean_test_data
  end

  it "allows exactly one checkout to hold the final ticket" do
    event = create(:event, :published, starts_at: 5.days.from_now)
    ticket_type = create(:ticket_type, event: event, quantity_available: 1, max_per_order: 1)

    outcomes = run_concurrently(2) do |index|
      Commerce::OrderCreator.call(
        event: Event.find(event.id),
        line_items: [{ ticket_type_id: ticket_type.id, quantity: 1 }],
        buyer_email: "buyer#{index}@example.com",
        buyer_name: "Buyer #{index}"
      )
    end

    expect(outcomes.count { |outcome| outcome.is_a?(Commerce::OrderCreator::Result) }).to eq(1)
    expect(outcomes.count { |outcome| outcome.is_a?(Commerce::OrderCreator::CheckoutError) }).to eq(1)
    expect(InventoryHold.current.sum(:quantity)).to eq(1)
    expect(ticket_type.reload.available_quantity).to eq(0)
  end

  it "recovers concurrent retries as the same order and inventory reservation" do
    SiteSetting.instance.update!(payment_mode: "test")
    allow(StripeService).to receive(:publishable_key).and_return("pk_test_recovery")
    allow(StripeService).to receive(:retrieve_payment_intent) do |payment|
      OpenStruct.new(id: payment.provider_payment_id, amount: payment.amount_cents, currency: payment.currency,
        status: "requires_payment_method", livemode: false, client_secret: "original_secret",
        allowed_payment_method_types: ["card"], payment_method_types: ["card"])
    end
    event = create(:event, :published, starts_at: 5.days.from_now)
    ticket_type = create(:ticket_type, event: event, quantity_available: 1, max_per_order: 1)
    digest = Digest::SHA256.hexdigest(SecureRandom.hex(32))
    outcomes = run_concurrently(2) do
      Commerce::OrderCreator.call(event: Event.find(event.id),
        line_items: [{ ticket_type_id: ticket_type.id, quantity: 1 }],
        buyer_email: "samebuyer@example.invalid", buyer_name: "Same Buyer",
        checkout_key_digest: digest, checkout_request_digest: "b" * 64)
    end
    results = outcomes.grep(Commerce::OrderCreator::Result)
    expect(results).not_to be_empty
    (outcomes - results).each do |error|
      if error.is_a?(CheckoutAttempt::Conflict)
        expect(error.recovery_required).to be(true)
      else
        expect(error).to be_a(Commerce::OrderCreator::CheckoutError)
        expect(error.message).to include("Payment setup is still in progress")
      end
    end
    recovered = Commerce::OrderCreator.call(event: Event.find(event.id),
      line_items: [{ ticket_type_id: ticket_type.id, quantity: 1 }],
      buyer_email: "samebuyer@example.invalid", buyer_name: "Same Buyer",
      checkout_key_digest: digest, checkout_request_digest: "b" * 64)
    expect((results.map { |result| result.order.id } + [recovered.order.id]).uniq.length).to eq(1)
    expect(Order.count).to eq(1)
    expect(InventoryHold.current.sum(:quantity)).to eq(1)
  end

  it "keeps an in-flight setup recoverable when a concurrent retry would conflict at the provider" do
    SiteSetting.instance.update!(payment_mode: "test")
    allow(StripeService).to receive(:publishable_key).and_return("pk_test_recovery")
    allow(StripeService).to receive(:retrieve_payment_intent) do |payment|
      OpenStruct.new(id: payment.provider_payment_id, amount: payment.amount_cents, currency: payment.currency,
        status: "requires_payment_method", livemode: false, client_secret: "original_secret",
        allowed_payment_method_types: ["card"], payment_method_types: ["card"])
    end
    event = create(:event, :published, starts_at: 5.days.from_now)
    ticket_type = create(:ticket_type, event: event, quantity_available: 1)
    arguments = { event: event, line_items: [{ ticket_type_id: ticket_type.id, quantity: 1 }],
      buyer_email: "samebuyer@example.invalid", buyer_name: "Same Buyer",
      checkout_key_digest: "d" * 64, checkout_request_digest: "e" * 64 }
    setup_started = Queue.new
    provider_started = Queue.new
    release_provider = Queue.new
    results = Queue.new
    allow_any_instance_of(Commerce::OrderCreator).to receive(:create_provider_payment!).and_wrap_original do |original, *args|
      setup_started << true
      original.call(*args)
    end
    calls = 0
    allow(StripeService).to receive(:create_payment_intent) do |sale_order, **|
      expect(ActiveRecord::Base.connection.transaction_open?).to be(false)
      calls += 1
      raise Stripe::APIConnectionError, "Concurrent provider request is unresolved" if calls > 1

      provider_started << true
      release_provider.pop
      OpenStruct.new(id: "pi_in_flight", client_secret: "original_secret", amount: sale_order.total_cents,
        allowed_payment_method_types: ["card"], payment_method_types: ["card"])
    end
    run_checkout = lambda do
      ActiveRecord::Base.connection_pool.with_connection do
        results << Commerce::OrderCreator.call(**arguments.merge(event: Event.find(event.id)))
      rescue StandardError => error
        results << error
      end
    end
    first = Thread.new(&run_checkout)
    Timeout.timeout(5) { provider_started.pop; setup_started.pop }
    second = Thread.new(&run_checkout)
    Timeout.timeout(5) { setup_started.pop }
    # The committed owner lets the competing request return promptly without
    # another POST or releasing inventory while the first request is in flight.
    early_result = Timeout.timeout(5) { results.pop }
    release_provider << true
    Timeout.timeout(5) { [first, second].each(&:join) }
    outcomes = Array(early_result) + results.size.times.map { results.pop }
    expect(Order.count).to eq(1)
    expect(Order.first.status).to eq("pending")
    expect(Payment.first).to have_attributes(status: "pending", provider_payment_id: "pi_in_flight")
    expect(InventoryHold.current.sum(:quantity)).to eq(1)
    expect(early_result).to be_a(Commerce::OrderCreator::CheckoutError)
    expect(early_result.message).to include("still in progress")
    recovered = outcomes.grep(Commerce::OrderCreator::Result)
    expect(recovered.length).to eq(1)
    expect(calls).to eq(1)
    expect(recovered.first.payment_intent.client_secret).to eq("original_secret")
    retry_result = Commerce::OrderCreator.call(**arguments.merge(event: Event.find(event.id)))
    expect(retry_result.order.id).to eq(recovered.first.order.id)
    expect(retry_result.payment_intent.client_secret).to eq("original_secret")
    expect(calls).to eq(1)
  ensure
    release_provider << true if release_provider&.empty?
    [first, second].compact.each { |thread| thread.kill if thread.alive? }
  end

  it "allows cancellation during setup and cancels the eventual intent without exposing its secret" do
    SiteSetting.instance.update!(payment_mode: "test")
    event = create(:event, :published, starts_at: 5.days.from_now)
    type = create(:ticket_type, event: event)
    allow(StripeService).to receive(:cancel_payment_intent) do
      expect(ActiveRecord::Base.connection.transaction_open?).to be(false)
      OpenStruct.new(status: "canceled")
    end
    allow(StripeService).to receive(:create_payment_intent) do |sale_order, **|
      expect(ActiveRecord::Base.connection.transaction_open?).to be(false)
      Commerce::OrderLifecycle.cancel!(Order.find(sale_order.id))
      OpenStruct.new(id: "pi_cancelled_setup", client_secret: "must_not_be_exposed",
        allowed_payment_method_types: ["card"], payment_method_types: ["card"])
    end
    result = Commerce::OrderCreator.call(event: event, line_items: [{ ticket_type_id: type.id, quantity: 1 }],
      buyer_name: "Cancel Buyer", buyer_email: "cancel@example.invalid", payment_required: true)
    expect(result.order).to be_cancelled
    expect(result.payment_intent).to be_nil
    expect(result.payment).to have_attributes(status: "cancelled", provider_payment_id: "pi_cancelled_setup")
    expect(result.order.inventory_holds).to all(be_released)
    expect(StripeService).to have_received(:cancel_payment_intent).with("pi_cancelled_setup",
      idempotency_key: "cancel:payment-setup:#{result.payment.id}", payment: result.payment)
  end

  it "fences a delayed owner before reservation after lease takeover and final rejection" do
    event = create(:event, :published, starts_at: 5.days.from_now)
    type = create(:ticket_type, event: event, quantity_available: 1)
    digest = Digest::SHA256.hexdigest(SecureRandom.hex(32))
    first = CheckoutAttempt.claim!(key_digest: digest, request_digest: "d" * 64)
    first.attempt.update!(lease_expires_at: 1.second.ago)
    second = CheckoutAttempt.claim!(key_digest: digest, request_digest: "d" * 64)
    expect(first.attempt.reject!(first.lease_token)).to be(false)
    expect(second.attempt.reject!(second.lease_token)).to be(true)

    expect do
      Commerce::OrderCreator.call(event: event, line_items: [{ ticket_type_id: type.id, quantity: 1 }],
        buyer_email: "late@example.invalid", buyer_name: "Late buyer", checkout_key_digest: digest,
        checkout_request_digest: "d" * 64, checkout_attempt: first.attempt, checkout_lease_token: first.lease_token)
    end.to raise_error(CheckoutAttempt::Conflict) { |error| expect(error.recovery_required).to be(false) }
    expect(Order.count).to eq(0)
    expect(InventoryHold.count).to eq(0)
    expect(StripeService).not_to have_received(:create_payment_intent)
  end

  it "allows a replacement owner to reserve while preventing the expired owner from duplicating it" do
    event = create(:event, :published, starts_at: 5.days.from_now)
    type = create(:ticket_type, event: event, quantity_available: 1)
    digest = Digest::SHA256.hexdigest(SecureRandom.hex(32))
    first = CheckoutAttempt.claim!(key_digest: digest, request_digest: "d" * 64)
    first.attempt.update!(lease_expires_at: 1.second.ago)
    second = CheckoutAttempt.claim!(key_digest: digest, request_digest: "d" * 64)
    options = { event: event, line_items: [{ ticket_type_id: type.id, quantity: 1 }], buyer_email: "late@example.invalid",
      buyer_name: "Late buyer", checkout_key_digest: digest, checkout_request_digest: "d" * 64 }
    expect do
      Commerce::OrderCreator.call(**options, checkout_attempt: first.attempt, checkout_lease_token: first.lease_token)
    end.to raise_error(CheckoutAttempt::Conflict) { |error| expect(error.recovery_required).to be(true) }

    allow(StripeService).to receive(:create_payment_intent) do |order, **|
      # Journal/order/inventory have committed before the first provider RPC.
      ActiveRecord::Base.connection_pool.with_connection do |connection|
        expect(connection.transaction_open?).to be(false)
      end
      expect(second.attempt.reload.order_id).to eq(order.id)
      raise StripeService::PaymentError, "Fixture response lost"
    end
    expect do
      Commerce::OrderCreator.call(**options, checkout_attempt: second.attempt, checkout_lease_token: second.lease_token)
    end.to raise_error(Commerce::OrderCreator::CheckoutError)
    expect(Order.count).to eq(1)
    expect(InventoryHold.count).to eq(1)
    expect(second.attempt.reload).to be_status_reserved
    expect(first.attempt.reject!(first.lease_token)).to be(false)
  end

  it "enforces shared event capacity across concurrent ticket types" do
    event = create(:event, :published, starts_at: 5.days.from_now, max_capacity: 1)
    types = [
      create(:ticket_type, event: event, quantity_available: 5, max_per_order: 5),
      create(:ticket_type, event: event, quantity_available: 5, max_per_order: 5)
    ]

    outcomes = run_concurrently(2) do |index|
      Commerce::OrderCreator.call(
        event: Event.find(event.id),
        line_items: [{ ticket_type_id: types[index].id, quantity: 1 }],
        buyer_email: "capacity#{index}@example.com",
        buyer_name: "Capacity #{index}"
      )
    end

    expect(outcomes.count { |outcome| outcome.is_a?(Commerce::OrderCreator::Result) }).to eq(1)
    expect(InventoryHold.current.sum(:quantity)).to eq(1)
  end

  it "allows exactly one box-office sale to consume the final door allocation" do
    event = create(:event, :published, starts_at: 5.days.from_now)
    ticket_type = create(
      :ticket_type,
      event: event,
      quantity_available: 10,
      door_allocation: 1,
      max_per_order: 1
    )

    outcomes = run_concurrently(2) do |index|
      Commerce::OrderCreator.call(
        event: Event.find(event.id),
        line_items: [{ ticket_type_id: ticket_type.id, quantity: 1 }],
        buyer_email: "door#{index}@example.com",
        buyer_name: "Door Buyer #{index}",
        payment_required: false,
        service_fee: false,
        source: "box_office",
        payment_method: "door_cash"
      )
    end

    expect(outcomes.count { |outcome| outcome.is_a?(Commerce::OrderCreator::Result) }).to eq(1)
    expect(outcomes.count { |outcome| outcome.is_a?(Commerce::OrderCreator::CheckoutError) }).to eq(1)
    expect(ticket_type.reload.door_sold_quantity).to eq(1)
    expect(ticket_type.door_available_quantity).to eq(0)
  end

  it "serializes competing refund requests so committed value cannot exceed the charge" do
    event = create(:event, :published, starts_at: 5.days.from_now)
    ticket_type = create(:ticket_type, event: event, quantity_sold: 1)
    order = create(:order, event: event, subtotal_cents: 5000, service_fee_cents: 250, total_cents: 5250)
    create(
      :order_item,
      order: order,
      ticket_type: ticket_type,
      unit_price_cents: 5000,
      subtotal_cents: 5000,
      fee_cents: 250,
      organizer_proceeds_cents: 5000
    )
    create(:payment, :succeeded, order: order, amount_cents: 5250, provider_payment_id: "sim_pi_concurrent_refund")

    outcomes = run_concurrently(2) do |index|
      Commerce::RefundCreator.call(
        order: Order.find(order.id),
        amount_cents: 4000,
        idempotency_key: "concurrent-refund-#{index}"
      )
    end

    expect(outcomes.count { |outcome| outcome.is_a?(Refund) }).to eq(1)
    expect(outcomes.count { |outcome| outcome.is_a?(Commerce::RefundCreator::RefundError) }).to eq(1)
    expect(order.refunds.succeeded.sum(:amount_cents)).to eq(4000)
    expect(order.reload.refundable_cents).to eq(1250)
  end

  it "recovers one cash order under concurrent identical requests for the last ticket" do
    event = create(:event, :published, starts_at: 5.days.from_now)
    user = event.organizer_profile.user
    ticket_type = create(:ticket_type, event: event, quantity_available: 1, max_per_order: 1, price_cents: 500)
    parameters = { line_items: [{ ticket_type_id: ticket_type.id, quantity: 1 }], payment_method: "door_cash" }

    outcomes = run_concurrently(2) do
      Commerce::CashSaleCreator.call(event: Event.find(event.id), user: user, parameters: parameters,
        idempotency_key: "concurrent-identical-cash")
    end

    expect(outcomes).to all(be_a(Commerce::CashSaleCreator::Result))
    expect(outcomes.map { |result| result.order.id }.uniq.length).to eq(1)
    expect(outcomes.map(&:replayed)).to contain_exactly(false, true)
    expect(Order.count).to eq(1)
    expect(Ticket.count).to eq(1)
    expect(Payment.succeeded.sum(:amount_cents)).to eq(500)
    expect(ticket_type.reload.quantity_sold).to eq(1)
  end

  it "rolls back the losing cash sale when different events race with the same key" do
    SiteSetting.instance
    events = 2.times.map { create(:event, :published, starts_at: 5.days.from_now) }
    types = events.map { |event| create(:ticket_type, event: event, price_cents: 500, quantity_available: 1) }

    outcomes = run_concurrently(2) do |index|
      event = Event.find(events[index].id)
      Commerce::CashSaleCreator.call(event: event, user: event.organizer_profile.user,
        parameters: { line_items: [{ ticket_type_id: types[index].id, quantity: 1 }], payment_method: "door_cash" },
        idempotency_key: "concurrent-conflicting-cash")
    end

    expect(outcomes.count { |result| result.is_a?(Commerce::CashSaleCreator::Result) }).to eq(1)
    expect(outcomes.count { |result| result.is_a?(Commerce::CashSaleCreator::Conflict) }).to eq(1)
    expect(Order.count).to eq(1)
    expect(Ticket.count).to eq(1)
    expect(Payment.succeeded.sum(:amount_cents)).to eq(500)
    expect(types.sum { |type| type.reload.quantity_sold }).to eq(1)
  end

  it "allows exactly one checkout to reserve the final catalog item" do
    event = create(:event, :published, starts_at: 5.days.from_now)
    ticket_type = create(:ticket_type, event: event, quantity_available: 2, max_per_order: 1)
    catalog_item = create(:catalog_item, event: event, inventory_quantity: 1)

    outcomes = run_concurrently(2) do |index|
      Commerce::OrderCreator.call(
        event: Event.find(event.id),
        line_items: [{ ticket_type_id: ticket_type.id, quantity: 1 }],
        catalog_items: [{ catalog_item_id: catalog_item.id, quantity: 1 }],
        buyer_email: "catalog#{index}@example.com",
        buyer_name: "Catalog #{index}"
      )
    end

    expect(outcomes.count { |outcome| outcome.is_a?(Commerce::OrderCreator::Result) }).to eq(1)
    expect(outcomes.count { |outcome| outcome.is_a?(Commerce::OrderCreator::CheckoutError) }).to eq(1)
    expect(CatalogItemHold.current.sum(:quantity)).to eq(1)
  end

  it "creates exactly one inventory-holding offer for concurrent waitlist actions" do
    event = create(:event, :published, starts_at: 5.days.from_now)
    ticket_type = create(:ticket_type, event: event, quantity_available: 2)
    entry = create(:waitlist_entry, event: event, ticket_type: ticket_type)
    allow(EmailService).to receive(:send_waitlist_offer_async)

    outcomes = run_concurrently(2) do
      WaitlistOffers::Issuer.call(entry: WaitlistEntry.find(entry.id))
    end

    expect(outcomes.count { |outcome| outcome.is_a?(WaitlistOffer) }).to eq(1)
    expect(outcomes.count { |outcome| outcome.is_a?(WaitlistOffers::Issuer::OfferError) }).to eq(1)
    expect(entry.waitlist_offers.holding_inventory.count).to eq(1)
  end

  it "creates exactly one pending transfer under concurrent requests" do
    owner = create(:user)
    event = create(:event, :published, starts_at: 5.days.from_now)
    ticket_type = create(:ticket_type, event: event)
    order = create(:order, event: event, user: owner, buyer_email: owner.email)
    item = create(:order_item, order: order, ticket_type: ticket_type)
    ticket = create(:ticket, event: event, ticket_type: ticket_type, order: order, order_item: item)
    allow(EmailService).to receive(:send_ticket_transfer_async)

    outcomes = run_concurrently(2) do |index|
      TicketTransfers::Manager.create!(ticket: Ticket.find(ticket.id), recipient_email: "recipient#{index}@example.com")
    end

    expect(outcomes.count { |outcome| outcome.is_a?(TicketTransfer) }).to eq(1)
    expect(outcomes.count { |outcome| outcome.is_a?(TicketTransfers::Manager::TransferError) }).to eq(1)
    expect(ticket.ticket_transfers.pending.count).to eq(1)
  end

  it "allows exactly one high-contention hold on the same assigned seat" do
    organization = create(:organization)
    profile = create(:organizer_profile, organization: organization)
    venue = create(:venue)
    event = create(:event, :published, organization: organization, organizer_profile: profile,
      venue: venue, starts_at: 5.days.from_now, max_capacity: 1)
    ticket_type = create(:ticket_type, event: event, quantity_available: 1)
    layout = create(:venue_layout, organization: organization, venue: venue)
    zone = create(:seating_price_zone, venue_layout: layout)
    section = create(:seating_section, venue_layout: layout)
    row = create(:seating_row, seating_section: section)
    create(:venue_seat, seating_row: row, seating_price_zone: zone)
    configuration = Seating::ConfigurationActivator.call(
      event: event,
      venue_layout: layout,
      zone_ticket_types: { zone.id => ticket_type.id },
      actor: profile.user
    )
    event_seat = configuration.event_seats.first

    outcomes = run_concurrently(2) do
      Seating::HoldAllocator.call(
        event: Event.find(event.id),
        event_seat_ids: [event_seat.id],
        accessibility_attested: false
      )
    end

    expect(outcomes.count { |outcome| outcome.is_a?(Seating::HoldAllocator::Result) }).to eq(1)
    expect(outcomes.count { |outcome| outcome.is_a?(Seating::HoldAllocator::HoldError) }).to eq(1)
    expect(event_seat.seat_holds.status_active.count).to eq(1)
  end

  %i[online box_office].each do |channel|
    it "serializes public seat release against a #{channel} checkout claiming the same session" do
      event, ticket_type, seat = assigned_inventory
      hold = Seating::HoldAllocator.call(event: event, event_seat_ids: [seat.id], accessibility_attested: false)
      release_checked = Queue.new
      continue_release = Queue.new
      checkout_lock = Queue.new
      release_results = Queue.new
      checkout_results = Queue.new
      allow_any_instance_of(SeatHold).to receive(:update!).and_wrap_original do |original, attributes|
        if Thread.current[:inventory_role] == :release && attributes[:status] == :released
          # Both the session guard and hold SELECT have completed. Pause before
          # the first mutation, while checkout attempts the same real DB rows.
          release_checked << true
          continue_release.pop
        end
        original.call(attributes)
      end
      allow_any_instance_of(SeatHoldSession).to receive(:lock!).and_wrap_original do |original, *args|
        if Thread.current[:inventory_role] == :checkout
          checkout_lock << ActiveRecord::Base.connection.select_value("SELECT pg_backend_pid()")
        end
        original.call(*args)
      end
      release_thread = inventory_worker(:release, release_results) do
        request = ActionDispatch::Integration::Session.new(Rails.application)
        request.delete "/api/v1/events/#{event.slug}/seat_holds", params: { token: hold.token }, as: :json
        [request.response.status, request.response.parsed_body.slice("status", "error", "errors")]
      end
      Timeout.timeout(5) { release_checked.pop }
      checkout_thread = inventory_worker(:checkout, checkout_results) do
        if channel == :online
          Commerce::OrderCreator.call(event: Event.find(event.id),
            line_items: [{ ticket_type_id: ticket_type.id, quantity: 1 }],
            buyer_name: "Synthetic Seat Buyer", buyer_email: "seat@synthetic.invalid", seat_hold_token: hold.token)
        else
          Commerce::CashSaleCreator.call(event: Event.find(event.id), user: event.organizer_profile.user,
            parameters: { line_items: [{ ticket_type_id: ticket_type.id, quantity: 1 }],
              buyer_name: "Synthetic Seat Buyer", buyer_email: "seat@synthetic.invalid",
              payment_method: "door_cash", seat_hold_token: hold.token }, idempotency_key: "synthetic-release-cash")
        end
      end
      pid = Timeout.timeout(5) { checkout_lock.pop }
      wait_for_database_lock_or_result(pid, checkout_results)
      continue_release << true
      Timeout.timeout(10) { [release_thread, checkout_thread].each(&:join) }
      release_result = release_results.pop
      checkout_result = checkout_results.pop

      expect(release_result.first).to eq(200),
        "release=#{release_result.inspect}, checkout=#{checkout_result.class}, session=#{hold.session.reload.status}"
      expect(checkout_result).to be_a(Commerce::OrderCreator::CheckoutError),
        "checkout=#{checkout_result.class}, session=#{hold.session.reload.status}, orders=#{Order.count}"
      expect(checkout_result.message).to include("invalid or expired")
      expect(Order.count).to eq(0)
      expect(hold.session.reload).to be_status_released
      expect(hold.session.seat_holds).to all(be_status_released)
      expect(seat.reload).to be_selectable
    ensure
      continue_release << true if continue_release&.empty?
      [release_thread, checkout_thread].compact.each { |thread| thread.kill if thread.alive? }
    end
  end

  it "finishes a claimed seat payment while a reused hold checkout waits without deadlocking" do
    event, ticket_type, seat = assigned_inventory
    hold = Seating::HoldAllocator.call(event: event, event_seat_ids: [seat.id], accessibility_attested: false)
    original = Commerce::OrderCreator.call(event: event,
      line_items: [{ ticket_type_id: ticket_type.id, quantity: 1 }], buyer_name: "Original Buyer",
      buyer_email: "original@synthetic.invalid", seat_hold_token: hold.token)
    finalization_locked = Queue.new
    continue_finalization = Queue.new
    checkout_lock = Queue.new
    finalization_results = Queue.new
    checkout_results = Queue.new
    pause_seat_finalization(finalization_locked, continue_finalization)
    finalization_thread = inventory_worker(:finalize, finalization_results) do
      Commerce::OrderLifecycle.complete!(Order.find(original.order.id), payment: Payment.find(original.payment.id),
        provider_amount_cents: original.order.total_cents, provider_currency: original.order.currency)
    end
    Timeout.timeout(5) { finalization_locked.pop }
    checkout_thread = inventory_worker(:checkout, checkout_results) do
      checkout_lock << ActiveRecord::Base.connection.select_value("SELECT pg_backend_pid()")
      Commerce::OrderCreator.call(event: Event.find(event.id),
        line_items: [{ ticket_type_id: ticket_type.id, quantity: 1 }], buyer_name: "Competing Buyer",
        buyer_email: "competing@synthetic.invalid", seat_hold_token: hold.token)
    end
    pid = Timeout.timeout(5) { checkout_lock.pop }
    wait_for_database_lock_or_result(pid, checkout_results)
    continue_finalization << true
    Timeout.timeout(10) { [finalization_thread, checkout_thread].each(&:join) }

    expect(finalization_results.pop).to eq(:completed)
    expect(checkout_results.pop).to be_a(Commerce::OrderCreator::CheckoutError)
    expect(Order.count).to eq(1)
    expect(original.order.reload).to be_completed
    expect(hold.session.reload).to be_status_consumed
    expect(seat.tickets.count).to eq(1)
    expect(ticket_type.reload.quantity_sold).to eq(1)
  ensure
    continue_finalization << true if continue_finalization&.empty?
    [finalization_thread, checkout_thread].compact.each { |thread| thread.kill if thread.alive? }
  end

  it "keeps a payment-finalized seat consumed when an independent public release waits" do
    event, ticket_type, seat = assigned_inventory
    hold = Seating::HoldAllocator.call(event: event, event_seat_ids: [seat.id], accessibility_attested: false)
    original = Commerce::OrderCreator.call(event: event,
      line_items: [{ ticket_type_id: ticket_type.id, quantity: 1 }], buyer_name: "Final Buyer",
      buyer_email: "final@synthetic.invalid", seat_hold_token: hold.token)
    finalization_locked = Queue.new
    continue_finalization = Queue.new
    release_lock = Queue.new
    finalization_results = Queue.new
    release_results = Queue.new
    allow_any_instance_of(SeatHoldSession).to receive(:lock!).and_wrap_original do |method, *args|
      release_lock << ActiveRecord::Base.connection.select_value("SELECT pg_backend_pid()") if Thread.current[:inventory_role] == :release
      result = method.call(*args)
      if Thread.current[:inventory_role] == :finalize && !Thread.current[:paused_finalization]
        Thread.current[:paused_finalization] = true
        finalization_locked << true
        continue_finalization.pop
      end
      result
    end
    finalization_thread = inventory_worker(:finalize, finalization_results) do
      Commerce::OrderLifecycle.complete!(Order.find(original.order.id), payment: Payment.find(original.payment.id),
        provider_amount_cents: original.order.total_cents, provider_currency: original.order.currency)
    end
    Timeout.timeout(5) { finalization_locked.pop }
    release_thread = inventory_worker(:release, release_results) do
      request = ActionDispatch::Integration::Session.new(Rails.application)
      request.delete "/api/v1/events/#{event.slug}/seat_holds", params: { token: hold.token }, as: :json
      [request.response.status, request.response.parsed_body.slice("status", "error", "errors")]
    end
    pid = Timeout.timeout(5) { release_lock.pop }
    wait_for_database_lock_or_result(pid, release_results)
    continue_finalization << true
    Timeout.timeout(10) { [finalization_thread, release_thread].each(&:join) }

    expect(finalization_results.pop).to eq(:completed)
    expect(release_results.pop).to eq([200, { "status" => "consumed" }])
    expect(hold.session.reload).to be_status_consumed
    expect(hold.session.seat_holds).to all(be_status_consumed)
    expect(seat.tickets.count).to eq(1)
    expect(seat.reload).not_to be_selectable
  ensure
    continue_finalization << true if continue_finalization&.empty?
    [finalization_thread, release_thread].compact.each { |thread| thread.kill if thread.alive? }
  end

  def pause_seat_finalization(ready, resume)
    allow_any_instance_of(SeatHoldSession).to receive(:lock!).and_wrap_original do |method, *args|
      result = method.call(*args)
      if Thread.current[:inventory_role] == :finalize && !Thread.current[:paused_finalization]
        Thread.current[:paused_finalization] = true
        ready << true
        resume.pop
      end
      result
    end
  end

  it "prevents online admission while a selected refund is in flight before releasing its seat" do
    event, ticket_type, seat = assigned_inventory
    ticket_type.update!(quantity_sold: 1)
    order = create(:order, event: event, subtotal_cents: 2500, service_fee_cents: 0, total_cents: 2500)
    item = create(:order_item, order: order, ticket_type: ticket_type, fee_cents: 0)
    ticket = create(:ticket, event: event, ticket_type: ticket_type, event_seat: seat, order: order, order_item: item)
    create(:payment, :succeeded, order: order, amount_cents: 2500, provider_payment_id: "sim_pi_selected_refund_race")
    actor = event.organizer_profile.user
    device = create(:scanner_device, organization: event.organization, event: event, user: actor)
    manifest = Admissions::ManifestBuilder.call(event: event, actor: actor)
    entry = manifest.payload.fetch("tickets").find { |candidate| candidate.fetch("ticket_id") == ticket.id }
    provider_started = Queue.new
    continue_provider = Queue.new
    refund_results = Queue.new
    allow(StripeService).to receive(:refund_payment) do |*args, **kwargs|
      provider_started << true
      continue_provider.pop
      OpenStruct.new(id: "sim_re_selected_refund_race", status: "succeeded", amount: kwargs.fetch(:amount_cents), currency: "usd")
    end
    refund_thread = inventory_worker(:refund, refund_results) do
      Commerce::RefundCreator.call(order: Order.find(order.id), tickets: [Ticket.find(ticket.id)],
        idempotency_key: "synthetic-selected-refund-race")
    end
    Timeout.timeout(5) { provider_started.pop }
    admission = Admissions::Reconciler.call(device: device, actor: actor, actions: [{
      action_uuid: "synthetic-refund-overlap", kind: "admit", source: "online", sequence: 1,
      manifest_version: manifest.version, occurred_at: Time.current.iso8601(6), ticket_id: ticket.id,
      credential_hash: entry.fetch("credential_hash")
    }]).first.action
    admitted_before_refund = ticket.reload.checked_in?
    continue_provider << true
    Timeout.timeout(10) { refund_thread.join }
    refund = refund_results.pop
    replacement_hold = Seating::HoldAllocator.call(event: Event.find(event.id), event_seat_ids: [seat.id], accessibility_attested: false)

    expect(refund).to be_a(Refund)
    expect(admission).to be_result_rejected,
      "admission=#{admission.result}, entered=#{admitted_before_refund}, ticket=#{ticket.reload.status}, replacement_hold=#{replacement_hold.session.status}"
    expect(admission.reason_code).to eq("refund_pending")
    expect(admitted_before_refund).to be(false)
    expect(ticket.reload).to be_cancelled
    expect(refund.reload).to be_succeeded
    expect(ticket_type.reload.quantity_sold).to eq(0)
    expect(replacement_hold.session).to be_status_active
  ensure
    continue_provider << true if continue_provider&.empty?
    refund_thread&.kill if refund_thread&.alive?
  end

  it "refuses a selected refund if admission commits first without contacting the provider" do
    event, ticket_type, seat = assigned_inventory
    ticket_type.update!(quantity_sold: 1)
    order = create(:order, event: event, subtotal_cents: 2500, service_fee_cents: 0, total_cents: 2500)
    item = create(:order_item, order: order, ticket_type: ticket_type, fee_cents: 0)
    ticket = create(:ticket, event: event, ticket_type: ticket_type, event_seat: seat, order: order, order_item: item)
    create(:payment, :succeeded, order: order, amount_cents: 2500, provider_payment_id: "sim_pi_admission_first")
    admission_checked = Queue.new
    continue_admission = Queue.new
    refund_started = Queue.new
    admission_results = Queue.new
    refund_results = Queue.new
    allow(StripeService).to receive(:refund_payment)
    allow_any_instance_of(Ticket).to receive(:update!).and_wrap_original do |method, attributes|
      if Thread.current[:inventory_role] == :admit && attributes[:status] == :checked_in
        admission_checked << true
        continue_admission.pop
      end
      method.call(attributes)
    end
    admission_thread = inventory_worker(:admit, admission_results) { Ticket.find(ticket.id).check_in! }
    Timeout.timeout(5) { admission_checked.pop }
    refund_thread = inventory_worker(:refund, refund_results) do
      refund_started << ActiveRecord::Base.connection.select_value("SELECT pg_backend_pid()")
      Commerce::RefundCreator.call(order: Order.find(order.id), tickets: [Ticket.find(ticket.id)],
        idempotency_key: "synthetic-admission-first-refund")
    end
    pid = Timeout.timeout(5) { refund_started.pop }
    wait_for_database_lock_or_result(pid, refund_results)
    continue_admission << true
    Timeout.timeout(10) { [admission_thread, refund_thread].each(&:join) }

    expect(admission_results.pop).to be(true)
    expect(refund_results.pop).to be_a(Commerce::RefundCreator::RefundError)
    expect(ticket.reload).to be_checked_in
    expect(ticket_type.reload.quantity_sold).to eq(1)
    expect(order.refunds.count).to eq(0)
    expect(StripeService).not_to have_received(:refund_payment)
    expect(seat.reload).not_to be_selectable
  ensure
    continue_admission << true if continue_admission&.empty?
    [admission_thread, refund_thread].compact.each { |thread| thread.kill if thread.alive? }
  end

  def assigned_inventory
    profile = create(:organizer_profile)
    venue = create(:venue)
    event = create(:event, :published, organizer_profile: profile, venue: venue,
      starts_at: 5.days.from_now, max_capacity: 1)
    ticket_type = create(:ticket_type, event: event, quantity_available: 1, price_cents: 2500)
    layout = create(:venue_layout, organization: event.organization, venue: venue)
    zone = create(:seating_price_zone, venue_layout: layout)
    row = create(:seating_row, seating_section: create(:seating_section, venue_layout: layout))
    create(:venue_seat, seating_row: row, seating_price_zone: zone)
    configuration = Seating::ConfigurationActivator.call(event: event, venue_layout: layout,
      zone_ticket_types: { zone.id => ticket_type.id }, actor: profile.user)
    [event, ticket_type, configuration.event_seats.first]
  end

  def inventory_worker(role, results)
    Thread.new do
      Thread.current[:inventory_role] = role
      ActiveRecord::Base.connection_pool.with_connection { results << yield }
    rescue StandardError => error
      results << error
    end
  end

  def wait_for_database_lock_or_result(pid, results)
    Timeout.timeout(5) do
      loop do
        break if !results.empty? || ActiveRecord::Base.connection.select_value("SELECT cardinality(pg_blocking_pids(#{Integer(pid)}))").positive?

        sleep 0.01
      end
    end
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
    connection = ActiveRecord::Base.connection
    connection.execute("SET lock_timeout = '5s'")
    connection.execute(<<~SQL)
      TRUNCATE TABLE users, organizer_profiles, events, site_settings, webhook_events, checkout_attempts
      RESTART IDENTITY CASCADE
    SQL
  ensure
    connection&.execute("SET lock_timeout = 0")
  end
end
