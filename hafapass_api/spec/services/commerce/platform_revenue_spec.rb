# frozen_string_literal: true

require "rails_helper"

# The dashboard's platform revenue must match the settlement statements: the
# processing-fee bearer comes from each order's snapshot, and only processing
# HåfaPass covers reduces its revenue.
RSpec.describe Commerce::PlatformRevenue do
  let(:profile) { create(:organizer_profile, :verified) }
  let(:event) { create(:event, :completed, organizer_profile: profile) }
  let(:other_event) { create(:event, :completed, organizer_profile: profile) }

  def record_sale!(sale_event, bearer:, ticket_cents: 5000, fee_cents: 350, donation_cents: 0, processing_cents: 185)
    order = create(:order, event: sale_event, subtotal_cents: ticket_cents + donation_cents, service_fee_cents: fee_cents,
      discount_cents: 0, total_cents: ticket_cents + donation_cents + fee_cents, processing_fee_bearer_snapshot: bearer)
    item = create(:order_item, order: order, unit_price_cents: ticket_cents, subtotal_cents: ticket_cents,
      fee_cents: fee_cents, organizer_proceeds_cents: ticket_cents)
    if donation_cents.positive?
      catalog = create(:catalog_item, event: sale_event, kind: :donation, price_cents: donation_cents,
        minimum_price_cents: donation_cents)
      create(:order_item, order: order, ticket_type: nil, catalog_item: catalog, item_kind: :donation, name: "Donation",
        unit_price_cents: donation_cents, subtotal_cents: donation_cents, fee_cents: 0, organizer_proceeds_cents: donation_cents)
    end
    create(:fee_component, order: order, kind: "platform", amount_cents: fee_cents, estimated: true)
    create(:fee_component, order: order, kind: "processing", amount_cents: processing_cents, estimated: false,
      provider_reference: "txn_revenue_#{SecureRandom.hex(4)}")
    [order, item]
  end

  def statement_totals(*events)
    events.map { |sale_event| Settlements::Calculator.call(sale_event).attributes }.then do |statements|
      {
        gross: statements.sum { |statement| statement[:platform_fee_cents] },
        platform_processing: statements.sum { |statement| statement[:platform_processing_fee_cents] },
        organizer_processing: statements.sum { |statement| statement[:processing_fee_cents] }
      }
    end
  end

  it "subtracts only the processing HåfaPass covers, for platform, organizer and legacy orders" do
    record_sale!(event, bearer: "platform")
    record_sale!(event, bearer: "organizer")
    record_sale!(other_event, bearer: nil)
    record_sale!(other_event, bearer: "platform", ticket_cents: 1000, fee_cents: 150, donation_cents: 10_000,
      processing_cents: 353)

    revenue = described_class.call

    # 350 + 350 + 350 + 150 in fees; HåfaPass covers 185 plus the 37 ticket
    # share of the mixed order; organizers bear 185 + 185 + 316.
    expect(revenue).to include(gross_platform_fee_cents: 1200, platform_processing_fee_cents: 222,
      organizer_processing_fee_cents: 686, net_platform_revenue_cents: 978)
    expect(revenue[:orders_by_processing_bearer]).to eq("platform" => 2, "organizer" => 1, "legacy" => 1)
    expect(statement_totals(event, other_event)).to eq(gross: 1200, platform_processing: 222, organizer_processing: 686)
  end

  it "removes refunded fees and ignores unsettled orders and estimated processing" do
    order, item = record_sale!(event, bearer: "platform")
    refund = create(:refund, order: order, amount_cents: 5350)
    create(:refund_item, refund: refund, order_item: item, amount_cents: 5350, organizer_proceeds_cents: 5000, fee_cents: 350)
    pending = create(:order, event: event, status: :pending, subtotal_cents: 5000, service_fee_cents: 350,
      total_cents: 5350, processing_fee_bearer_snapshot: "platform")
    create(:fee_component, order: pending, kind: "platform", amount_cents: 350)
    estimated_order, = record_sale!(other_event, bearer: "platform", processing_cents: 1)
    create(:fee_component, order: estimated_order, kind: "processing", amount_cents: 999, estimated: true)

    revenue = described_class.call

    expect(revenue).to include(gross_platform_fee_cents: 350, platform_processing_fee_cents: 186,
      net_platform_revenue_cents: 164)
    expect(statement_totals(event, other_event)).to include(gross: 350, platform_processing: 186)
  end

  it "reports zeros when there are no settled orders" do
    expect(described_class.call).to include(gross_platform_fee_cents: 0, platform_processing_fee_cents: 0,
      organizer_processing_fee_cents: 0, net_platform_revenue_cents: 0, orders_by_processing_bearer: {})
  end
end
