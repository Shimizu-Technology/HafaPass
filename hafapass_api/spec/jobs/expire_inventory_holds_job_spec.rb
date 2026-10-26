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
