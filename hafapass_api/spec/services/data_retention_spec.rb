require "rails_helper"

RSpec.describe DataRetention do
  describe "schedule inventory" do
    it "classifies every application table and every directly sensitive column" do
      excluded = %w[ar_internal_metadata schema_migrations site_settings runtime_executions runtime_throttle_buckets]
      tables = ActiveRecord::Base.connection.data_sources.reject { |table| table.start_with?("solid_queue_") || excluded.include?(table) }
      expect(described_class.schedule.keys.sort).to eq(tables.sort)

      sensitive = /(?:email|phone|address|\Atin\z|_tin\z|ip_address|recipient|payload|answer|clerk_id|\A(?:first_name|last_name|buyer_name|attendee_name|guest_name|legal_name|signer_name|contact_name|name)\z)/
      tables.each do |table|
        rule = described_class.schedule.fetch(table)
        expect(rule).to include("category", "period", "trigger", "action", "pii_columns")
        expect(%w[anonymize delete keep]).to include(rule.fetch("action"))
        columns = ActiveRecord::Base.connection.columns(table).map(&:name)
        expect(columns).to include(rule.fetch("trigger"))
        expect(rule.fetch("pii_columns") - columns).to be_empty
        expect(columns.grep(sensitive) - rule.fetch("pii_columns") - rule.fetch("reviewed_non_pii_columns", [])).to be_empty,
          "Classify new sensitive columns in #{table}"
      end
    end
  end

  it "uses the end of the calendar year for the seven-year clock" do
    expect(described_class.cutoff("7_years_after_year_end", at: Time.zone.parse("2026-10-22")))
      .to eq(Time.zone.parse("2019-01-01"))
  end

  it "removes buyer and attendee details while preserving money rows and amounts" do
    user = create(:user)
    order = create(:order, user: user, completed_at: 8.years.ago, buyer_email: "buyer@example.com")
    ticket = create(:ticket, order: order, ticket_type: create(:ticket_type, event: order.event),
      attendee_name: "Buyer", attendee_email: "attendee@example.com", holder_email: "buyer@example.com")
    payment = create(:payment, order: order, amount_cents: order.total_cents,
      provider_payload: { "billing_details" => { "email" => "buyer@example.com" } })

    described_class.anonymize_order!(order)

    expect(order.reload).to have_attributes(total_cents: 5250, user_id: nil, buyer_name: "Deleted buyer",
      buyer_phone: nil)
    expect(order.buyer_email).to end_with("@privacy.invalid")
    expect(order.retention_anonymized_at).to be_present
    expect(ticket.reload).to have_attributes(attendee_name: nil, attendee_email: nil, holder_email: nil)
    expect(payment.reload).to have_attributes(amount_cents: 5250, provider_payload: {})
    expect { described_class.anonymize_order!(order) }.not_to change { order.reload.buyer_email }
  end
end
