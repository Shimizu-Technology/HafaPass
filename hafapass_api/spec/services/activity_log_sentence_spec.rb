# frozen_string_literal: true

require "rails_helper"

RSpec.describe ActivityLogSentence do
  def sentence(action, before: {}, after: {}, metadata: {}, type: "Event", id: 42, event_id: 7)
    entry = AuditLog.new(action: action, before_data: before, after_data: after, metadata: metadata,
      auditable_type: type, auditable_id: id, event_id: event_id)
    described_class.new(entry, actor_name: "Mina Cruz").call
  end

  it "names the ticket and compares prices and inventory without using disallowed fields" do
    expect(sentence("ticket_type.updated", before: { price_cents: 2000 }, after: { price_cents: 2500, buyer_email: "private@example.test" },
      metadata: { subject_label: "General Admission", buyer_name: "Private Buyer" })).to eq("Mina Cruz changed General Admission's price from $20.00 to $25.00.")
    expect(sentence("ticket_type.updated", before: { quantity_available: 100 }, after: { quantity_available: 150 },
      metadata: { subject_label: "VIP" })).to eq("Mina Cruz changed VIP's inventory from 100 to 150.")
  end

  it "identifies refund/dispute amounts and orders and formats non-USD money explicitly" do
    expect(sentence("refund.failed", metadata: { order_reference: "HP-1042", amount_cents: 4500 })).to eq("Mina Cruz reported that a $45.00 refund for order HP-1042 failed.")
    expect(sentence("dispute.opened", after: { amount_cents: 4500, currency: "eur" }, metadata: { order_reference: "HP-1042" })).to eq("Mina Cruz reported a dispute on order HP-1042 for 45.00 EUR.")
  end

  it "names team invitees and roles but never interpolates raw buyer or private metadata" do
    expect(sentence("organization.invitation_created", metadata: { team_member_label: "ana@example.com", team_role: "box_office" })).to eq("Mina Cruz invited ana@example.com as Box office.")
    expect(sentence("event.updated", metadata: { event_title: "Reef Night", buyer_email: "private@example.test", note: "Private" })).to eq("Mina Cruz updated Reef Night.")
  end

  it "falls back to record identities for historical/deleted subjects" do
    expect(sentence("ticket_type.updated", type: "TicketType")).to eq("Mina Cruz updated ticket type #42.")
    expect(sentence("refund.failed", type: "Refund")).to eq("Mina Cruz reported that refund #42 failed.")
    expect(sentence("event.deleted")).to eq("Mina Cruz deleted event #7.")
  end

  it "captures context for partial updates at the real logger boundary" do
    event = create(:event, title: "Reef Night")
    ticket_type = create(:ticket_type, event: event, name: "General Admission", price_cents: 2000)
    AuditContext.set(actor: event.organizer_profile.user, source: "user") { ticket_type.update!(price_cents: 2500) }
    log = AuditLog.where(action: "ticket_type.updated", auditable: ticket_type).last!
    expect(log.metadata).to include("subject_label" => "General Admission", "event_title" => "Reef Night")
    expect(ActivityLogPresenter.new(log, organization: event.organization).organization_json[:sentence]).to eq("John Doe changed General Admission's price from $20.00 to $25.00.")
  end

  it "renders every registry action safely even when old records have no snapshots" do
    AuditActions.keys.each do |key|
      expect(sentence(key)).to start_with("Mina Cruz ")
      expect(sentence(key)).not_to include("{}", "  ")
    end
  end
end
