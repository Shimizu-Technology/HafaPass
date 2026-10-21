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
    expect(row).to include(gross_ticket_proceeds_cents: 4800, refunds_cents: 600, fees_collected_cents: 450,
      fees_refunded_cents: 100, net_paid_cents: 1700, w9_on_file: true)
    expect(row[:tax_information]).to include("masked_tin" => "***-**-5678")
    expect(report.months[9]).to include(fees_collected_cents: 450, fees_refunded_cents: 100,
      gross_receipts_cents: 350, card_processing_costs_cents: 80)
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

  it "counts a successful live capture even when a failed test attempt exists" do
    at = Time.utc(2026, 10, 2)
    order = sale(at: at)
    create(:payment, order: order, status: :failed, provider_environment: "test")
    simulated = sale(at: at, environment: "simulate")
    allow(Rails.env).to receive(:production?).and_return(true)
    expect(Order.excluding_test_payments).to include(order)
    expect(Order.excluding_test_payments).not_to include(simulated)
    expect(Settlements::Calculator.new(event).send(:orders)).to include(order)
    expect(described_class.new(2026).organizers.sole[:gross_ticket_proceeds_cents]).to eq(2400)
  end

  it "reports legacy NULL-environment live sales and excludes payload-confirmed test payments" do
    at = Time.utc(2026, 10, 2)
    legacy = sale(at: at, environment: nil)
    create(:payment, order: legacy, status: :failed, provider_environment: "test")
    test_order = sale(at: at, environment: nil)
    test_order.payments.first.update!(provider_payload: { "livemode" => false })
    allow(Rails.env).to receive(:production?).and_return(true)

    expect(described_class.new(2026).organizers.sole[:gross_ticket_proceeds_cents]).to eq(2400)
    expect(described_class.new(2026).months[9][:gross_receipts_cents]).to eq(225)
    expect(Settlements::Calculator.new(event).send(:orders)).to include(legacy)
    expect(Settlements::Calculator.new(event).send(:orders)).not_to include(test_order)
  end

  it "loads organizer details only for organizations with period activity" do
    at = Time.utc(2026, 10, 2)
    sale(at: at)
    3.times { create(:organization) }
    report = described_class.new(2026)
    expect(Organization).to receive(:where).with(id: [organization.id]).and_call_original
    expect(report.organizers.map { |row| row[:organization_id] }).to eq([organization.id])
  end

  it "reconciles ticket, add-on and donation gross with a partial refund and paid payout" do
    at = Time.utc(2026, 10, 2)
    order = create(:order, :completed, event: event, completed_at: at, subtotal_cents: 4000,
      service_fee_cents: 225, total_cents: 4225)
    ticket = create(:order_item, order: order, unit_price_cents: 2500, subtotal_cents: 2500,
      fee_cents: 225, organizer_proceeds_cents: 2275)
    addon = create(:order_item, order: order, ticket_type: nil, catalog_item: create(:catalog_item, event: event),
      item_kind: :add_on, name: "Add-on", unit_price_cents: 1000, subtotal_cents: 1000, fee_cents: 0)
    create(:order_item, order: order, ticket_type: nil, catalog_item: create(:catalog_item, :donation, event: event),
      item_kind: :donation, name: "Donation", unit_price_cents: 500, subtotal_cents: 500, fee_cents: 0)
    payment = create(:payment, :succeeded, order: order, provider_environment: "live")
    create(:fee_component, order: order, kind: "platform", amount_cents: 225)
    returned = create(:refund, order: order, payment: payment, succeeded_at: at, amount_cents: 900)
    create(:refund_item, refund: returned, order_item: ticket, amount_cents: 500,
      organizer_proceeds_cents: 450, fee_cents: 50)
    create(:refund_item, refund: returned, order_item: addon, amount_cents: 400,
      organizer_proceeds_cents: 400, fee_cents: 0)
    account = create(:connected_account, organization: organization)
    create(:payout, event: event, organization: organization, connected_account: account,
      settlement: create(:settlement, event: event, organization: organization), status: :paid,
      amount_cents: 2925, paid_at: at)
    row = described_class.new(2026).organizers.sole
    expect(row).to include(gross_ticket_proceeds_cents: 2500, gross_add_on_proceeds_cents: 1000,
      gross_donation_proceeds_cents: 500, gross_non_ticket_proceeds_cents: 1500,
      ticket_refunds_cents: 500, non_ticket_refunds_cents: 400, fee_refunds_cents: 50,
      unallocated_refunds_cents: 0, fees_collected_cents: 225, reconciliation_adjustments_cents: 0, net_paid_cents: 2925)
    expect(row[:gross_ticket_proceeds_cents] + row[:gross_non_ticket_proceeds_cents] -
      row[:ticket_refunds_cents] - row[:non_ticket_refunds_cents] - row[:unallocated_refunds_cents] - row[:fees_collected_cents] +
      row[:fee_refunds_cents] + row[:reconciliation_adjustments_cents]).to eq(row[:net_paid_cents])
  end
end
