require "rails_helper"

RSpec.describe ExpireInventoryHoldsJob do
  it "releases every due order idempotently" do
    order = create(:order, :pending, expires_at: 1.minute.ago)
    item = create(:order_item, order: order)
    hold = create(:inventory_hold, order: order, order_item: item, expires_at: 1.minute.ago)

    expect do
      described_class.perform_now(Time.current)
    end.to change { order.reload.status }.from("pending").to("expired")
      .and change { hold.reload.status }.from("active").to("expired")

    expect do
      described_class.perform_now(Time.current)
    end.not_to change { [order.reload.status, hold.reload.status] }
  end

  describe "with a slow payment provider" do
    let(:event) { create(:event, :published, starts_at: 5.days.from_now) }
    let(:ticket_type) { create(:ticket_type, event: event, price_cents: 2500, quantity_available: 10) }

    before do
      SiteSetting.instance.update!(payment_mode: "test")
      allow(StripeService).to receive_messages(payment_enabled?: true, card_only_intent?: true)
      allow(StripeService).to receive(:create_payment_intent) do
        OpenStruct.new(id: "pi_slow_#{SecureRandom.hex(4)}", client_secret: "secret")
      end
      allow(StripeService).to receive(:cancel_payment_intent).and_return(OpenStruct.new(status: "canceled"))
      # Every status check hangs past the (shortened) provider timeout.
      allow(StripeService).to receive(:retrieve_payment_intent) { sleep 2 }
      stub_const("Commerce::OrderLifecycle::PROVIDER_CHECK_TIMEOUT", 0.2.seconds)
      allow(Rails.logger).to receive(:warn).and_call_original
    end

    def lapsed_order(index)
      order = Commerce::OrderCreator.call(event: event, line_items: [{ ticket_type_id: ticket_type.id, quantity: 2 }],
        buyer_email: "slow-#{index}@example.com", buyer_name: "Slow Buyer").order
      order.update_columns(expires_at: 1.minute.ago)
      order.inventory_holds.update_all(expires_at: 1.minute.ago)
      order
    end

    it "times out each status check, stops at the run budget and leaves the rest for the next run" do
      orders = 3.times.map { |index| lapsed_order(index) }

      described_class.perform_now(Time.current, budget: 0.3.seconds)

      expect(orders.first.reload).to be_expired
      expect(orders.last.reload).to be_pending
      expect(Rails.logger).to have_received(:warn).with(a_string_including('"event":"order_expiry_payment_check_failed"')).at_least(:once)
      expect(Rails.logger).to have_received(:warn).with(a_string_including('"event":"order_expiry_budget_exhausted"'))
      # A deferred order's lapsed holds no longer reserve inventory.
      expect(ticket_type.reload.available_quantity).to eq(10)

      described_class.perform_now(Time.current)
      expect(orders.map { |order| order.reload.status }).to all(eq("expired"))
      expect(StripeService).to have_received(:cancel_payment_intent).exactly(3).times
    end
  end

  it "reports one failed transfer expiry and still expires later invitations exactly once" do
    event = create(:event, :published)
    ticket = create(:ticket, event: event, order: create(:order, event: event),
      ticket_type: create(:ticket_type, event: event))
    failed = create(:ticket_transfer, ticket: ticket, expires_at: 1.minute.ago)
    later_ticket = create(:ticket, event: event, order: create(:order, event: event), ticket_type: ticket.ticket_type)
    later = create(:ticket_transfer, ticket: later_ticket, expires_at: 1.minute.ago)
    failed_version, later_version = failed.token_version, later.token_version
    failure = ActiveRecord::LockWaitTimeout.new("synthetic held parent")
    allow(Sentry).to receive(:capture_exception)
    allow(Rails.logger).to receive(:error)
    allow(TicketTransfers::Manager).to receive(:expire!).and_wrap_original do |original, transfer, **options|
      raise failure if transfer.id == failed.id

      original.call(transfer, **options)
    end

    described_class.perform_now(Time.current)

    expect(failed.reload).to be_pending
    expect(failed).not_to be_active
    expect(failed.token_version).to eq(failed_version)
    expect(later.reload).to be_expired
    expect(later.token_version).to eq(later_version + 1)
    expect(AuditLog.where(action: "ticket_transfer.expired", auditable: later).count).to eq(1)
    expect(AuditLog.where(action: "ticket_transfer.expired", auditable: failed)).not_to exist
    expect(Sentry).to have_received(:capture_exception).with(failure)
    expect(Rails.logger).to have_received(:error).with({ event: "ticket_transfer_expiry_failed",
      ticket_transfer_id: failed.id, error_class: failure.class.name }.to_json)

    described_class.perform_now(Time.current)
    expect(later.reload.token_version).to eq(later_version + 1)
    expect(AuditLog.where(action: "ticket_transfer.expired", auditable: later).count).to eq(1)
  end

  it "requeues expired waitlist offers and closes stale transfer invitations" do
    event = create(:event, :published)
    type = create(:ticket_type, event: event)
    entry = create(:waitlist_entry, event: event, ticket_type: type, status: :offered)
    offer = create(:waitlist_offer, waitlist_entry: entry, event: event, ticket_type: type,
      expires_at: 1.minute.ago)
    order = create(:order, event: event)
    item = create(:order_item, order: order, ticket_type: type)
    ticket = create(:ticket, order: order, event: event, ticket_type: type, order_item: item)
    transfer = create(:ticket_transfer, ticket: ticket, expires_at: 1.minute.ago)

    described_class.perform_now(Time.current)

    expect(offer.reload).to be_expired
    expect(entry.reload).to be_waiting
    expect(transfer.reload).to be_expired
  end
end
