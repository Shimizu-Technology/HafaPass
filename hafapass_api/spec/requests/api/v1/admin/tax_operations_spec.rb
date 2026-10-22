# frozen_string_literal: true

require "rails_helper"
require "csv"
require "tempfile"
require "stringio"

RSpec.describe "Admin tax operations", type: :request do
  let(:admin) { create(:user, :admin) }
  let(:organization) { create(:organization) }
  let!(:tax) { create(:organizer_tax_information, organization: organization) }

  it "requires admin and keeps all ordinary JSON and audit metadata masked" do
    get "/api/v1/admin/tin_matching", headers: auth_headers(create(:user))
    expect(response).to have_http_status(:forbidden)
    get "/api/v1/admin/tin_matching", headers: auth_headers(admin)
    expect(response).to have_http_status(:ok)
    expect(response.parsed_body.dig("payees", 0, "tax_information", "masked_tin")).to eq("***-**-5678")
    expect(response.body).not_to include(tax.tin)
    get "/api/v1/admin/annual_tax_reports", params: { year: 2026 }, headers: auth_headers(admin)
    expect(response.body).not_to include(tax.tin)
  end

  it "exports and imports an IRS result file with no complete TIN in the response or audit" do
    post "/api/v1/admin/tin_matching/export", headers: auth_headers(admin)
    expect(response).to have_http_status(:ok)
    expect(response.headers["Cache-Control"]).to include("no-store")
    line = response.body.strip
    expect(line.split(";").length).to eq(4)
    Tempfile.create(["tin-result", ".txt"]) do |file|
      file.write("#{line};3\n")
      file.flush
      upload = Rack::Test::UploadedFile.new(file.path, "text/plain")
      post "/api/v1/admin/tin_matching/import", params: { file: upload }, headers: auth_headers(admin)
    end
    expect(response).to have_http_status(:ok)
    expect(response.parsed_body).to eq("imported" => 1, "statuses" => { "mismatch" => 1 })
    expect(response.body).not_to include(tax.tin)
    expect(tax.reload.tin_match_status).to eq("mismatch")
    expect(AuditLog.where(action: "tin_matching.imported").last.metadata.to_json).not_to include(tax.tin)
  end

  it "filters the matching upload and TIN from request logs" do
    post "/api/v1/admin/tin_matching/export", headers: auth_headers(admin)
    request_line = response.body.strip
    filtered = ActiveSupport::ParameterFilter.new(Rails.application.config.filter_parameters)
      .filter(tin: tax.tin, file: "#{request_line};3")
    expect(filtered.to_json).not_to include(tax.tin)

    stream = StringIO.new
    logger = ActiveSupport::Logger.new(stream)
    logger.level = Logger::DEBUG
    previous_logger = Rails.logger
    Rails.logger = logger
    begin
      Tempfile.create(["tin-result", ".txt"]) do |file|
        file.write("#{request_line};3\n")
        file.flush
        post "/api/v1/admin/tin_matching/import",
          params: { file: Rack::Test::UploadedFile.new(file.path, "text/plain") }, headers: auth_headers(admin)
      end
    ensure
      Rails.logger = previous_logger
    end
    expect(response).to have_http_status(:ok)
    expect(stream.string).not_to include(tax.tin)
  end

  it "audits a rejected result import without retaining upload content" do
    post "/api/v1/admin/tin_matching/import", headers: auth_headers(admin)

    expect(response).to have_http_status(:unprocessable_entity)
    audit = AuditLog.where(action: "tin_matching.import_failed").last
    expect(audit.metadata).to eq("reason" => "missing_file")
    expect(audit.metadata.to_json).not_to include(tax.tin)
  end

  it "tracks first and second notice dates and rejects a TIN in flag reasons" do
    tax.update!(tin_match_status: "mismatch")
    post "/api/v1/admin/organizations/#{organization.id}/tax_information/b_notice_pdf",
      params: { stage: "first" }, headers: auth_headers(admin)
    expect(response).to have_http_status(:ok)
    expect(response.media_type).to eq("application/pdf")
    expect(response.body).not_to include(tax.tin)
    post "/api/v1/admin/organizations/#{organization.id}/tax_information/notice_received",
      params: { received_on: 60.days.ago.to_date.iso8601 }, headers: auth_headers(admin)
    expect(response).to have_http_status(:ok)
    post "/api/v1/admin/organizations/#{organization.id}/tax_information/b_notice_sent",
      params: { stage: "first", sent_on: 60.days.ago.to_date.iso8601 }, headers: auth_headers(admin)
    expect(response).to have_http_status(:ok)
    expect(tax.reload.b_notice_response_due_on).to eq(BNotice.business_days_after(60.days.ago.to_date, 30))
    post "/api/v1/admin/organizations/#{organization.id}/tax_information/notice_received",
      params: { received_on: Date.current.iso8601 }, headers: auth_headers(admin)
    post "/api/v1/admin/organizations/#{organization.id}/tax_information/b_notice_sent",
      params: { stage: "second", sent_on: Date.current.iso8601 }, headers: auth_headers(admin)
    expect(response).to have_http_status(:ok)
    expect(tax.reload.b_notice_stage).to eq("second")
    expect(tax.irs_notice_received_on).to eq(Date.current)
    expect(tax.b_notice_response_due_on).to eq(BNotice.business_days_after(Date.current, 30))
    post "/api/v1/admin/organizations/#{organization.id}/tax_information/validate_second_notice",
      params: { evidence_type: "ssa_card", recorded_on: Date.current.iso8601 }, headers: auth_headers(admin)
    expect(response).to have_http_status(:unprocessable_entity)
    post "/api/v1/admin/organizations/#{organization.id}/tax_information/validate_second_notice",
      params: { evidence_type: "irs_letter_147c", recorded_on: Date.current.iso8601,
        document_reference: "locked cabinet reference" }, headers: auth_headers(admin)
    expect(response).to have_http_status(:ok)
    expect(tax.reload).to have_attributes(irs_validation_evidence_type: "irs_letter_147c",
      irs_validation_admin_id: admin.id, tin_match_status: "matched")
    expect(AuditLog.where(action: "tax_information.second_b_notice_validated").last.metadata.to_json).not_to include(tax.tin)
    patch "/api/v1/admin/organizations/#{organization.id}/tax_information/withholding_flag",
      params: { flagged: true, reason: "TIN #{tax.tin} is wrong" }, headers: auth_headers(admin)
    expect(response).to have_http_status(:unprocessable_entity)
    expect(AuditLog.where(action: "tax_information.withholding_flag_changed")).to be_empty
  end

  it "keeps annual CSV full TIN access audited and JSON masked" do
    event = create(:event, organization: organization)
    create(:payout, organization: organization, event: event,
      settlement: create(:settlement, organization: organization, event: event),
      connected_account: create(:connected_account, organization: organization),
      status: :paid, amount_cents: 10_003, withheld_cents: 2401,
      paid_at: Time.utc(2026, 10, 4))
    key = AnnualPayeeReport.payee_key_for(organization.payouts.last)
    patch "/api/v1/admin/annual_tax_reports/#{organization.id}",
      params: { year: 2026, payee_key: key, form_type: "1099-misc", jurisdiction: "guam_drt" }, headers: auth_headers(admin)
    expect(response).to have_http_status(:ok)
    expect(response.parsed_body).to include("form_type" => "1099-misc", "jurisdiction" => "guam_drt",
      "gross_paid_cents" => 10_003, "withheld_cents" => 2401)
    expect(response.body).not_to include(tax.tin)
    post "/api/v1/admin/annual_tax_reports/export", params: { year: 2026 }, headers: auth_headers(admin)
    expect(response).to have_http_status(:ok)
    row = CSV.parse(response.body, headers: true).first
    expect(row["payee_tin"]).to eq("***-**-5678")
    expect(response.body).not_to include(tax.tin)
    post "/api/v1/admin/annual_tax_reports/export",
      params: { year: 2026, include_full_tins: true, purpose: "CPA filing preparation" }, headers: auth_headers(admin)
    expect(CSV.parse(response.body, headers: true).first["payee_tin"]).to eq(tax.tin)
    expect(response.headers["Content-Disposition"]).to include("SENSITIVE-FULL-TINS")
    expect(row["payer_tin"]).to eq("SET_TAX_PAYER_TIN")
    audit = AuditLog.where(action: "annual_tax_report.exported").last
    expect(audit.metadata).to include("count" => 1, "purpose" => "CPA filing preparation", "full_tins" => true)
    expect(audit.metadata.to_json).not_to include(tax.tin)
  end

  it "masks a formatted payer TIN in the default annual CSV" do
    allow(ENV).to receive(:[]).and_call_original
    allow(ENV).to receive(:[]).with("TAX_PAYER_TIN").and_return("12-3456789")
    post "/api/v1/admin/annual_tax_reports/export", params: { year: 2026 }, headers: auth_headers(admin)
    expect(response).to have_http_status(:ok)
    expect(response.body).not_to include("12-3456789")
  end

  it "lists a refund-only payee in the refund year" do
    event = create(:event, organization: organization)
    order = create(:order, event: event)
    item = create(:order_item, order: order)
    settlement = create(:settlement, organization: organization, event: event)
    settlement.settlement_items.create!(kind: "sale_proceeds", amount_cents: 500,
      currency: organization.currency, description: "Sale", occurred_at: Time.utc(2026, 9, 1),
      source_type: "OrderItem", source_id: item.id)
    create(:payout, organization: organization, event: event, settlement: settlement,
      connected_account: create(:connected_account, organization: organization),
      status: :paid, paid_at: Time.utc(2026, 10, 1))
    refund = create(:refund, order: order, amount_cents: 500, succeeded_at: Time.utc(2027, 1, 2))
    create(:refund_item, refund: refund, order_item: item, amount_cents: 500,
      organizer_proceeds_cents: 450, fee_cents: 50)
    get "/api/v1/admin/annual_tax_reports", params: { year: 2027 }, headers: auth_headers(admin)
    expect(response).to have_http_status(:ok)
    expect(response.parsed_body["reports"].first).to include("organization_id" => organization.id,
      "gross_paid_cents" => 0, "refund_clawbacks_cents" => 450)
  end

  it "requires a purpose for a full-TIN export" do
    post "/api/v1/admin/annual_tax_reports/export", params: { year: 2026, include_full_tins: true }, headers: auth_headers(admin)
    expect(response).to have_http_status(:unprocessable_entity)
    expect(AuditLog.where(action: "annual_tax_report.exported")).not_to exist
  end

  it "checks upload length before reading IRS results" do
    expect(TinMatching).not_to receive(:import!)
    # A real oversized upload exercises Rack's request path without parsing its content.
    Tempfile.create(["oversize", ".txt"]) do |file|
      file.truncate(12_000_001)
      post "/api/v1/admin/tin_matching/import", params: { file: Rack::Test::UploadedFile.new(file.path, "text/plain") }, headers: auth_headers(admin)
    end
    expect(response).to have_http_status(:unprocessable_entity)
    expect(response.parsed_body["error"]).to include("too large")
  end
end
