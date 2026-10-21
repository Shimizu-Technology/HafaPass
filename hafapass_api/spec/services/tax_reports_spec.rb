# frozen_string_literal: true

require "rails_helper"

RSpec.describe TaxReports do
  let(:organization) { create(:organization) }
  let(:profile) { create(:organizer_profile, organization: organization) }
  let(:event) { create(:event, organization: organization, organizer_profile: profile) }

  def sale(at:, environment: "live", gross: 2500, fee: 225)
    order = create(:order, :completed, event: event, completed_at: at)
    create(:order_item, order: order, unit_price_cents: gross, subtotal_cents: gross, discount_cents: 100,
      organizer_proceeds_cents: gross - 150, organizer_fee_cents: 50)
    create(:payment, :succeeded, order: order, provider_environment: environment, succeeded_at: at)
    create(:fee_component, order: order, kind: "platform", amount_cents: fee, estimated: true)
    order
  end

  def refund(order, at:, status: :succeeded)
    result = create(:refund, order: order, payment: order.payments.first, succeeded_at: at, status: status, amount_cents: 600)
    create(:refund_item, refund: result, order_item: order.order_items.first,
      amount_cents: 600, organizer_proceeds_cents: 500, fee_cents: 75, organizer_fee_cents: 25, tax_cents: 0)
    result
  end

  it "reports live collections, allocated refunds, actual processing and actually paid payouts" do
    at = Time.find_zone!("Pacific/Guam").local(2026, 10, 1)
    order = sale(at: at)
    create(:fee_component, order: order, kind: "processing", estimated: false, amount_cents: 80)
    create(:fee_component, order: order, kind: "processing", estimated: true, amount_cents: 999)
    %w[test simulate].each { |environment| refund(sale(at: at, environment: environment), at: at) }
    sale(at: at, environment: nil)
    create(:payment, :succeeded, order: order, provider_environment: "live")
    refund(order, at: at + 1.day)
    refund(order, at: at + 1.day, status: :failed)
    account = create(:connected_account, organization: organization)
    settlement = create(:settlement, event: event, organization: organization)
    create(:payout, event: event, organization: organization, settlement: settlement, connected_account: account,
      amount_cents: 1700, status: :paid, paid_at: at, created_at: at - 1.year)
    create(:payout, event: event, organization: organization, settlement: settlement, connected_account: account,
      amount_cents: 999, status: :processing)
    report = described_class.new(2026)
    row = report.organizers.sole
    expect(row).to include(gross_ticket_proceeds_cents: 2400, refunds_cents: 600, fees_collected_cents: 225,
      fees_refunded_cents: 100, net_paid_cents: 1700, w9_on_file: true)
    expect(row[:tax_information]).to include("masked_tin" => "***-**-5678")
    expect(report.months[9]).to include(fees_collected_cents: 225, fees_refunded_cents: 100,
      gross_receipts_cents: 125, card_processing_costs_cents: 80)
    expect(report.as_json.to_json).not_to include("012345678")
  end

  it "uses Guam midnight and independent refund dates, including negative and refund-only years" do
    order = sale(at: Time.utc(2025, 12, 31, 13, 59))
    refund(order, at: Time.utc(2025, 12, 31, 14, 0))
    report = described_class.new(2026)
    expect(report.organizers.sole).to include(gross_ticket_proceeds_cents: 0, refunds_cents: 600, fees_collected_cents: 0)
    expect(report.months.first).to include(gross_receipts_cents: -100, fees_refunded_cents: 100)
    expect(described_class.new(2025).months.last[:gross_receipts_cents]).to eq(225)
    sale(at: Time.utc(2026, 12, 31, 14, 0))
    expect(report.months.sum { |month| month[:fees_collected_cents] }).to eq(0)
  end

  it "includes payout-only years, excludes reversed payouts and excludes payouts on test-only events" do
    sale(at: Time.utc(2025, 8, 1))
    account = create(:connected_account, organization: organization)
    settlement = create(:settlement, event: event, organization: organization)
    paid = create(:payout, event: event, organization: organization, settlement: settlement, connected_account: account,
      amount_cents: 1700, status: :paid, paid_at: Time.utc(2026, 1, 3))
    expect(described_class.new(2026).organizers.sole).to include(gross_ticket_proceeds_cents: 0, net_paid_cents: 1700)
    test_event = create(:event, organization: organization, organizer_profile: profile)
    test_order = create(:order, :completed, event: test_event, completed_at: Time.utc(2026, 1, 1))
    create(:payment, :succeeded, order: test_order, provider_environment: "test")
    create(:payout, event: test_event, organization: organization,
      settlement: create(:settlement, event: test_event, organization: organization), connected_account: account,
      amount_cents: 999, status: :paid, paid_at: Time.utc(2026, 1, 3))
    expect(described_class.new(2026).organizers.sole[:net_paid_cents]).to eq(1700)
    paid.update!(status: :reversed)
    expect(described_class.new(2026).organizers).to be_empty
  end

  it "validates the selected calendar year" do
    ["garbage", "2026junk", 1900, 2101].each { |value| expect { described_class.new(value) }.to raise_error(ArgumentError) }
  end
end
