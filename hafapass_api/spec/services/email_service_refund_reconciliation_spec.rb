require "rails_helper"

RSpec.describe EmailService, "refund reconciliation digest" do
  let!(:first_admin) { create(:user, :admin, email: "finance@example.com") }
  let!(:second_admin) { create(:user, :admin, email: "operations@example.com") }
  let!(:organizer) { create(:user, :organizer) }
  let(:event) { create(:event, :published) }
  let(:items) do
    [{ type: "refund", id: 42, status: "failed", amount_cents: 5250,
      order_reference: "HP-42", buyer_name: "Buyer", event_id: event.id,
      event_title: "Concert", overdue: true }]
  end

  it "queues one durable, idempotent digest per admin for a calendar day" do
    expect do
      described_class.send_refund_reconciliation_digest_async(items, date: Date.current)
      described_class.send_refund_reconciliation_digest_async(items, date: Date.current)
    end.to change { MessageDelivery.where(template: "refund_reconciliation_digest").count }.by(2)

    deliveries = MessageDelivery.where(template: "refund_reconciliation_digest")
    expect(deliveries.pluck(:recipient)).to match_array([first_admin.email, second_admin.email])
    expect(deliveries.pluck(:recipient)).not_to include(organizer.email)
    expect(deliveries.map(&:idempotency_key).uniq.length).to eq(2)
    expect(deliveries).to all(be_queued)
  end

  it "skips the digest when there are no outstanding items" do
    expect do
      described_class.send_refund_reconciliation_digest_async([], date: Date.current)
    end.not_to change(MessageDelivery, :count)
  end
end
