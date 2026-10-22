require "rails_helper"

RSpec.describe DataRetentionPurgeJob do
  before do
    allow(ENV).to receive(:[]).and_call_original
    allow(ENV).to receive(:[]).with("DATA_RETENTION_DESTRUCTIVE_ENABLED").and_return("true")
    SiteSetting.instance.update_columns(retention_purge_enabled: true)
  end

  it "starts in production dry-run mode until an admin enables purge" do
    allow(Rails.env).to receive(:production?).and_return(true)
    allow(ENV).to receive(:[]).with("DATA_RETENTION_DRY_RUN").and_return(nil)
    setting = SiteSetting.instance
    setting.update_columns(retention_purge_enabled: false)

    expect(DataRetention.dry_run?).to be(true)
    setting.update!(retention_purge_enabled: true)
    expect(DataRetention.dry_run?).to be(false)
  end

  it "counts only when the server kill switch is unset, even after admin enablement" do
    old = create(:order, completed_at: 8.years.ago)
    allow(ENV).to receive(:[]).with("DATA_RETENTION_DESTRUCTIVE_ENABLED").and_return(nil)

    expect(described_class.perform_now.fetch("orders")).to eq(1)
    expect(old.reload.buyer_email).to eq("buyer@example.com")
  end

  it "defaults to a count-only dry run when forced by the environment" do
    old = create(:order, completed_at: 8.years.ago)
    allow(ENV).to receive(:[]).and_call_original
    allow(ENV).to receive(:[]).with("DATA_RETENTION_DRY_RUN").and_return("true")

    counts = described_class.perform_now

    expect(counts.fetch("orders")).to eq(1)
    expect(old.reload.buyer_email).to eq("buyer@example.com")
  end

  it "stops writing at the next batch when the admin disables purge" do
    stub_const("DataRetention::BATCH_SIZE", 1)
    first = create(:order, completed_at: 8.years.ago)
    second = create(:order, completed_at: 8.years.ago)
    writes = 0
    allow(DataRetention).to receive(:anonymize!).and_wrap_original do |original, record|
      result = original.call(record)
      if record.is_a?(Order) && (writes += 1) == 1
        SiteSetting.instance.update_columns(retention_purge_enabled: false)
      end
      result
    end

    expect(described_class.perform_now.fetch("orders")).to eq(2)
    expect(writes).to eq(1)
    expect(first.reload.buyer_email).to end_with("@privacy.invalid")
    expect(second.reload.buyer_email).to eq("buyer@example.com")
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

  it "preserves a shared reconciliation digest for an old order with a pending refund" do
    order = create(:order, completed_at: 8.years.ago)
    create(:refund, order: order, status: :pending)
    digest = create(:message_delivery, order: nil, event: order.event, recipient: "ops@example.test",
      template: "refund_reconciliation_digest",
      status: :sent, created_at: 8.years.ago,
      metadata: { items: [{ order_reference: order.reference, reason: "needs follow-up" }] })

    described_class.perform_now

    expect(order.reload.retention_anonymized_at).to be_nil
    expect(digest.reload.metadata.dig("items", 0, "reason")).to eq("needs follow-up")
  end

  it "keeps an old order while a provider webhook still awaits processing" do
    order = create(:order, completed_at: 8.years.ago)
    webhook = WebhookEvent.create!(provider: "stripe", provider_event_id: SecureRandom.uuid,
      event_type: "payment.updated", status: :received,
      payload: { data: { object: { order_reference: order.reference } } })

    described_class.perform_now

    expect(webhook.reload.payload.dig("data", "object", "order_reference")).to eq(order.reference)
    expect(order.reload.retention_anonymized_at).to be_nil
  end

  it "keeps an old order for a received Stripe intent with metadata order_id" do
    order = create(:order, completed_at: 8.years.ago)
    receipt = WebhookEvent.create!(provider: "stripe", provider_event_id: SecureRandom.uuid,
      event_type: "payment_intent.processing", status: :received,
      payload: { data: { object: { id: "pi_unlinked", metadata: { order_id: order.id.to_s } } } })

    described_class.perform_now

    expect(receipt.reload.payload.dig("data", "object", "metadata", "order_id")).to eq(order.id.to_s)
    expect(order.reload.retention_anonymized_at).to be_nil
  end

  it "rechecks a hold created after the scan and before the locked write" do
    order = create(:order, completed_at: 8.years.ago)
    actor = create(:user, :admin)
    checks = 0
    allow(RetentionGuard).to receive(:protected?).and_wrap_original do |original, record|
      result = original.call(record)
      if record.is_a?(Order) && record.id == order.id && (checks += 1) == 1
        LegalHold.place!(scope_type: "order", scope_value: order.id.to_s,
          reason: "Preserve during litigation", actor: actor)
      end
      result
    end

    described_class.perform_now

    expect(checks).to be >= 2
    expect(order.reload.buyer_email).to eq("buyer@example.com")
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
