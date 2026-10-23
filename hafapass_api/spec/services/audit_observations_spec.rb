# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Audit provider observations" do
  it "retains a later webhook mismatch after a refund timeout observation" do
    refund = create(:refund)
    AuditLogger.record!(action: "refund.unknown", auditable: refund, source: "provider", outcome: "unknown",
      deduplication_key: "refund:#{refund.id}:unknown", metadata: { code: "provider_result_unknown" })
    receipt = WebhookEvent.create!(provider: "stripe", provider_event_id: "evt-audit-mismatch",
      event_type: "refund.updated", payload: {})
    processor = StripeWebhookProcessor.new(event: nil, payload: {})
    processor.send(:record_refund_provider_issue!, receipt, refund, code: "refund_operation_mismatch", action: "unknown")
    rows = AuditLog.where(action: "refund.unknown", auditable: refund)
    expect(rows.count).to eq(2)
    expect(rows.map { |row| row.metadata.fetch("code") }).to contain_exactly("provider_result_unknown", "refund_operation_mismatch")
    expect(rows.map(&:source).uniq).to eq(["provider"])
  end
end
