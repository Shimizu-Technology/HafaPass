# frozen_string_literal: true

require "rails_helper"
require "csv"

RSpec.describe "Admin tax reporting", type: :request do
  include ActiveSupport::Testing::TimeHelpers
  let(:admin) { create(:user, :admin) }
  let(:organization) { create(:organization, name: "=UNTRUSTED") }
  let!(:tax) { create(:organizer_tax_information, organization: organization) }

  before do
    event = create(:event, organization: organization, organizer_profile: create(:organizer_profile, organization: organization))
    order = create(:order, :completed, event: event, completed_at: Time.utc(2026, 10, 2))
    create(:order_item, order: order)
    create(:payment, :succeeded, order: order, provider_environment: "live")
    create(:fee_component, order: order, amount_cents: 225)
    account = create(:connected_account, organization: organization)
    create(:payout, organization: organization, event: event,
      settlement: create(:settlement, organization: organization, event: event), connected_account: account,
      status: :paid, amount_cents: 2000, paid_at: Time.utc(2026, 10, 3))
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

  it "keeps the payout identity and TIN when the current W-9 changes during preparation" do
    allow(AuditLogger).to receive(:record!).and_wrap_original do |original, **arguments|
      result = original.call(**arguments)
      tax.update!(legal_name: "Updated Payee", tin: "987654321") if arguments[:action] == "tax_report.exported"
      result
    end
    post "/api/v1/admin/tax_reports/preparation_export", params: { year: 2026 }, headers: auth_headers(admin)
    row = CSV.parse(response.body, headers: true).first
    expect(row["legal_name"]).to eq("Island Events LLC")
    expect(row["full_tin_for_1099_preparation_import_as_text"]).to eq("012345678")
  end

  it "separates W-9 versions and leaves legacy payout TINs blank in both CSVs" do
    event = organization.events.first
    account = organization.connected_accounts.first
    settlement = organization.settlements.first
    tax.update!(legal_name: "New Legal Name", tin: "987654321")
    create(:payout, organization: organization, event: event, settlement: settlement, connected_account: account,
      status: :paid, amount_cents: 100, paid_at: Time.utc(2026, 10, 4))
    create(:payout, organization: organization, event: event, settlement: settlement, connected_account: account,
      status: :paid, amount_cents: 100, paid_at: Time.utc(2026, 10, 5), with_tax_snapshot: false)

    get "/api/v1/admin/tax_reports/organizers_export", params: { year: 2026 }, headers: auth_headers(admin)
    masked = CSV.parse(response.body, headers: true)
    expect(masked.length).to eq(3)
    expect(masked.map { |row| row["legal_name"] }).to contain_exactly("Island Events LLC", "New Legal Name", "")
    legacy = masked.find { |row| row["snapshot_status"] == "No W-9 on file at payout" }
    expect(legacy["masked_tin"]).to be_blank
    expect(response.body).not_to include("012345678", "987654321")

    post "/api/v1/admin/tax_reports/preparation_export", params: { year: 2026 }, headers: auth_headers(admin)
    full = CSV.parse(response.body, headers: true)
    expect(full.map { |row| row["full_tin_for_1099_preparation_import_as_text"] })
      .to contain_exactly("012345678", "987654321", "")
    legacy = full.find { |row| row["snapshot_status"] == "No W-9 on file at payout" }
    expect(legacy["full_tin_for_1099_preparation_import_as_text"]).to be_blank
  end

  it "throttles full-TIN reveal and export together per admin and per IP" do
    freeze_time do
      headers = auth_headers(admin)
      9.times do
        post "/api/v1/admin/organizations/#{organization.id}/tax_information/reveal", headers: headers
        expect(response).to have_http_status(:ok)
      end
      post "/api/v1/admin/tax_reports/preparation_export", params: { year: 2026 }, headers: headers
      expect(response).to have_http_status(:ok)
      post "/api/v1/admin/organizations/#{organization.id}/tax_information/reveal", headers: headers
      expect(response).to have_http_status(:too_many_requests)
      expect(response.parsed_body["error"]).to include("Too many full-TIN requests")
      expect(response.body).not_to include(tax.tin)
    end
  end

  it "applies the admin budget across IPs" do
    freeze_time do
      headers = auth_headers(admin)
      10.times do |index|
        post "/api/v1/admin/organizations/#{organization.id}/tax_information/reveal",
          headers: headers.merge("REMOTE_ADDR" => "198.51.100.#{index + 1}")
        expect(response).to have_http_status(:ok)
      end
      post "/api/v1/admin/organizations/#{organization.id}/tax_information/reveal",
        headers: headers.merge("REMOTE_ADDR" => "198.51.100.50")
      expect(response).to have_http_status(:too_many_requests)
    end
  end

  it "applies the IP budget across different admins" do
    freeze_time do
      another = create(:user, :admin)
      first_headers = auth_headers(admin).merge("REMOTE_ADDR" => "198.51.100.80")
      second_headers = auth_headers(another).merge("REMOTE_ADDR" => "198.51.100.80")
      5.times do
        post "/api/v1/admin/organizations/#{organization.id}/tax_information/reveal", headers: first_headers
        expect(response).to have_http_status(:ok)
        post "/api/v1/admin/organizations/#{organization.id}/tax_information/reveal", headers: second_headers
        expect(response).to have_http_status(:ok)
      end
      post "/api/v1/admin/organizations/#{organization.id}/tax_information/reveal", headers: first_headers
      expect(response).to have_http_status(:too_many_requests)
    end
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
