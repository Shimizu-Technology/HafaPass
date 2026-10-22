require "rails_helper"

RSpec.describe DataRetentionPurgeJob do
  it "starts in production dry-run mode until an admin enables purge" do
    allow(Rails.env).to receive(:production?).and_return(true)
    allow(ENV).to receive(:[]).and_call_original
    allow(ENV).to receive(:[]).with("DATA_RETENTION_DRY_RUN").and_return(nil)
    setting = SiteSetting.instance

    expect(DataRetention.dry_run?).to be(true)
    setting.update!(retention_purge_enabled: true)
    expect(DataRetention.dry_run?).to be(false)
  end

  it "defaults to a count-only dry run when forced by the environment" do
    old = create(:order, completed_at: 8.years.ago)
    allow(ENV).to receive(:[]).and_call_original
    allow(ENV).to receive(:[]).with("DATA_RETENTION_DRY_RUN").and_return("true")

    counts = described_class.perform_now

    expect(counts.fetch("orders")).to eq(1)
    expect(old.reload.buyer_email).to eq("buyer@example.com")
  end

  it "skips holds and only anonymizes an eligible order once" do
    held = create(:order, completed_at: 8.years.ago)
    other = create(:order, completed_at: 8.years.ago)
    LegalHold.place!(scope_type: "order", scope_value: held.id.to_s,
      reason: "Preserve during litigation", actor: create(:user, :admin))

    expect(described_class.perform_now.fetch("orders")).to eq(1)
    expect(held.reload.buyer_email).to eq("buyer@example.com")
    expect(other.reload.buyer_email).to end_with("@privacy.invalid")
    expect(described_class.perform_now.fetch("orders", 0)).to eq(0)
  end

  it "blocks an old order while a dispute remains open" do
    order = create(:order, completed_at: 8.years.ago)
    Dispute.create!(order: order, provider: "stripe", provider_dispute_id: "dp_retention_test",
      amount_cents: 100, currency: "usd", opened_at: Time.current, status: :open)

    described_class.perform_now

    expect(order.reload.retention_anonymized_at).to be_nil
  end

  it "deletes an abandoned pending order and its checkout children after 90 days" do
    order = create(:order, :pending, created_at: 100.days.ago, expires_at: 100.days.ago)
    item = create(:order_item, order: order)

    expect(described_class.perform_now.fetch("abandoned_orders")).to eq(1)

    expect(Order.exists?(order.id)).to be(false)
    expect(OrderItem.exists?(item.id)).to be(false)
  end

  it "redacts payment payloads after the finance window and keeps the amount" do
    order = create(:order, completed_at: 8.years.ago)
    payment = create(:payment, order: order, created_at: 8.years.ago,
      provider_payload: { "customer_email" => "buyer@example.com" })

    described_class.perform_now

    expect(payment.reload).to have_attributes(amount_cents: order.total_cents, provider_payload: {})
    expect(payment.retention_anonymized_at).to be_present
  end
end
