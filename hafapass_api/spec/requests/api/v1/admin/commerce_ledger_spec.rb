require "rails_helper"

RSpec.describe "Admin commerce ledger", type: :request do
  let(:admin) { create(:user, :admin) }
  let(:headers) { auth_headers(admin) }
  let(:order) { create(:order, subtotal_cents: 5000, service_fee_cents: 250, total_cents: 5250) }
  let!(:item) do
    create(
      :order_item,
      order: order,
      unit_price_cents: 5000,
      subtotal_cents: 5000,
      fee_cents: 250,
      organizer_proceeds_cents: 5000
    )
  end
  let!(:fee) { create(:fee_component, order: order, amount_cents: 250) }
  let!(:payment) { create(:payment, :succeeded, order: order, amount_cents: 5250) }

  it "returns auditable items, payments, refunds, totals, and reconciliation state" do
    refund = create(:refund, order: order, payment: payment, amount_cents: 1000)
    create(:refund_item, refund: refund, order_item: item, amount_cents: 1000)
    create(:reconciliation_exception, order: order, payment: payment, code: "manual_review")

    get "/api/v1/admin/orders", headers: headers

    expect(response).to have_http_status(:ok)
    record = response.parsed_body.fetch("orders").find { |candidate| candidate["id"] == order.id }
    expect(record).to include(
      "subtotal_cents" => 5000,
      "fee_cents" => 250,
      "refund_cents" => 1000,
      "net_cents" => 4250,
      "organizer_proceeds_cents" => 4000
    )
    expect(record.fetch("order_items").first).to include("name" => item.name, "unit_price_cents" => 5000)
    expect(record.fetch("payments").first).to include("status" => "succeeded")
    expect(record.fetch("refunds").first).to include("amount_cents" => 1000)
    expect(record.fetch("reconciliation_exceptions").first).to include("code" => "manual_review")
  end

  it "returns separate dashboard financial totals" do
    get "/api/v1/admin/dashboard", headers: headers

    expect(response).to have_http_status(:ok)
    expect(response.parsed_body.fetch("financials")).to include(
      "gross_cents" => 5000,
      "discount_cents" => 0,
      "refund_cents" => 0,
      "net_cents" => 5250,
      "fee_cents" => 250,
      "organizer_proceeds_cents" => 5000,
      "payout_ready_cents" => 5000
    )
  end
end
