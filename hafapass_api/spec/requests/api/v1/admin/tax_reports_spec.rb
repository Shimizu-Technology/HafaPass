# frozen_string_literal: true

require "rails_helper"
require "csv"

RSpec.describe "Admin tax reporting", type: :request do
  let(:admin) { create(:user, :admin) }
  let(:organization) { create(:organization, name: "=UNTRUSTED") }
  let!(:tax) { create(:organizer_tax_information, organization: organization) }

  before do
    event = create(:event, organization: organization, organizer_profile: create(:organizer_profile, organization: organization))
    order = create(:order, :completed, event: event, completed_at: Time.utc(2026, 10, 2))
    create(:order_item, order: order)
    create(:payment, :succeeded, order: order, provider_environment: "live")
    create(:fee_component, order: order, amount_cents: 225)
  end

  it "requires admin for reports, exports and reveals" do
    headers = auth_headers(create(:user))
    ["/api/v1/admin/tax_reports", "/api/v1/admin/tax_reports/organizers_export", "/api/v1/admin/tax_reports/receipts_export"].each do |path|
      get path, params: { year: 2026 }, headers: headers
      expect(response).to have_http_status(:forbidden)
    end
    post "/api/v1/admin/tax_reports/preparation_export", params: { year: 2026 }, headers: headers
    expect(response).to have_http_status(:forbidden)
    post "/api/v1/admin/organizations/#{organization.id}/tax_information/reveal", headers: headers
    expect(response).to have_http_status(:forbidden)
  end

  it "shows masked W-9 data on the organization detail even before live sales" do
    get "/api/v1/admin/organizations/#{organization.id}", headers: auth_headers(admin)
    expect(response).to have_http_status(:ok)
    expect(response.parsed_body.dig("tax_information", "masked_tin")).to eq("***-**-5678")
    expect(response.body).not_to include(tax.tin)
    expect(response.headers["Cache-Control"]).to include("no-store")
  end

  it "normally returns only masked tax data and validates years" do
    get "/api/v1/admin/tax_reports", params: { year: 2026 }, headers: auth_headers(admin)
    expect(response).to have_http_status(:ok)
    expect(response.body).not_to include(tax.tin)
    expect(response.parsed_body["months"].length).to eq(12)
    get "/api/v1/admin/tax_reports", params: { year: "x" }, headers: auth_headers(admin)
    expect(response).to have_http_status(:unprocessable_entity)
  end

  it "reveals a full TIN only through an audited POST with no caching" do
    expect do
      post "/api/v1/admin/organizations/#{organization.id}/tax_information/reveal", headers: auth_headers(admin)
    end.to change { AuditLog.where(action: "organizer_tax_information.revealed").count }.by(1)
    expect(response.parsed_body).to eq("tin" => "012345678")
    expect(response.headers["Cache-Control"]).to include("no-store")
    audit = AuditLog.where(action: "organizer_tax_information.revealed").last
    expect(audit.actor_user).to eq(admin)
    expect(audit.metadata.to_json).not_to include(tax.tin)
    get "/api/v1/admin/tax_reports", params: { year: 2026 }, headers: auth_headers(admin)
    expect(response.body).not_to include(tax.tin)
  end

  it "exports formula-safe masked CSV and explicit audited full TINs for preparation" do
    get "/api/v1/admin/tax_reports/organizers_export", params: { year: 2026 }, headers: auth_headers(admin)
    expect(response.media_type).to eq("text/csv")
    expect(response.body).not_to include(tax.tin)
    row = CSV.parse(response.body, headers: true).first
    expect(row["organization"]).to eq("\t=UNTRUSTED")
    expect(row["gross_ticket_proceeds"]).to eq("25.00")
    expect(row["masked_tin"]).to eq("***-**-5678")
    post "/api/v1/admin/tax_reports/preparation_export", params: { year: 2026 }, headers: auth_headers(admin)
    expect(response).to have_http_status(:ok)
    expect(CSV.parse(response.body, headers: true).first["full_tin_for_1099_preparation_import_as_text"]).to eq(tax.tin)
    audit = AuditLog.where(action: "tax_report.exported").last
    expect(audit.metadata).to include("year" => 2026, "export" => "1099_preparation_full_tin", "organization_ids" => [organization.id])
    expect(audit.metadata.to_json).not_to include(tax.tin)
    expect(response.headers["Cache-Control"]).to include("no-store")
  end

  it "exports identity and TIN from one record version when tax details change during preparation" do
    allow(AuditLogger).to receive(:record!).and_wrap_original do |original, **arguments|
      result = original.call(**arguments)
      tax.update!(legal_name: "Updated Payee", tin: "987654321") if arguments[:action] == "tax_report.exported"
      result
    end
    post "/api/v1/admin/tax_reports/preparation_export", params: { year: 2026 }, headers: auth_headers(admin)
    row = CSV.parse(response.body, headers: true).first
    expect(row["legal_name"]).to eq("Updated Payee")
    expect(row["full_tin_for_1099_preparation_import_as_text"]).to eq("987654321")
  end

  it "does not reveal or export when audit recording fails" do
    allow(AuditLogger).to receive(:record!).and_raise(ActiveRecord::RecordInvalid.new(AuditLog.new))
    post "/api/v1/admin/organizations/#{organization.id}/tax_information/reveal", headers: auth_headers(admin)
    expect(response).to have_http_status(:unprocessable_entity)
    expect(response.body).not_to include(tax.tin)
    post "/api/v1/admin/tax_reports/preparation_export", params: { year: 2026 }, headers: auth_headers(admin)
    expect(response).to have_http_status(:unprocessable_entity)
    expect(response.body).not_to include(tax.tin)
  end

  it "exports twelve monthly receipts with service fees separate from costs" do
    get "/api/v1/admin/tax_reports/receipts_export", params: { year: 2026 }, headers: auth_headers(admin)
    rows = CSV.parse(response.body, headers: true)
    expect(rows.length).to eq(12)
    expect(rows[9].to_h).to include("month" => "2026-10", "gross_receipts" => "2.25", "card_processing_costs" => "0.00")
  end
end
