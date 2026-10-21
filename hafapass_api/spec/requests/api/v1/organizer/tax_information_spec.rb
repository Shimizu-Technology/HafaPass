# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Organizer tax information", type: :request do
  let(:owner) { create(:user, :organizer) }
  let(:profile) { create(:organizer_profile, user: owner) }
  let(:organization) { profile.organization }
  let(:headers) { auth_headers(owner).merge("X-Organization-Id" => organization.id.to_s) }
  let(:values) do
    { legal_name: "Island Events LLC", business_name: "Island Nights", tax_classification: "llc_c",
      tin_type: "ein", tin: "012345678", mailing_address: "PO Box 1, GU 96910", signer_name: "Alex Owner", certified: true }
  end

  it "shows missing status, then saves and returns only masked information with a server timestamp" do
    get "/api/v1/organizer/tax_information", headers: headers
    expect(response.parsed_body).to include("tax_information" => nil, "edit_locked" => false)
    expect(response.parsed_body["certification"]).to include("Under penalties of perjury")
    patch "/api/v1/organizer/tax_information", params: { tax_information: values.merge(certified_at: 10.years.ago) }, headers: headers
    expect(response).to have_http_status(:ok)
    expect(response.body).not_to include("012345678")
    expect(response.parsed_body["tax_information"]).to include("masked_tin" => "***-**-5678", "w9_on_file" => true)
    expect(organization.reload.organizer_tax_information.certified_at).to be_within(5.seconds).of(Time.current)
    expect(AuditLog.where(action: "organizer_tax_information.updated")).to exist
    get "/api/v1/organizer/tax_information", headers: headers
    expect(response.body).not_to include("012345678")
    expect(response.headers["Cache-Control"]).to include("no-store")
  end

  it "requires certification, typed name, valid TIN, and ignores client last-four" do
    [values.merge(certified: false), values.merge(signer_name: ""), values.merge(tin: "123")].each do |bad|
      patch "/api/v1/organizer/tax_information", params: { tax_information: bad }, headers: headers
      expect(response).to have_http_status(:unprocessable_entity)
    end
    expect(OrganizerTaxInformation.count).to eq(0)
    patch "/api/v1/organizer/tax_information", params: { tax_information: values.merge(tin_last_four: "9999") }, headers: headers
    expect(response.parsed_body.dig("tax_information", "masked_tin")).to eq("***-**-5678")
  end

  it "invalidates all existing payout approvals, without placing TINs in audits" do
    account = create(:connected_account, organization: organization)
    expect(account).to be_payout_ready
    patch "/api/v1/organizer/tax_information", params: { tax_information: values }, headers: headers
    expect(response).to have_http_status(:ok)
    expect(account.reload).not_to be_payout_ready
    expect(account.active_payment_readiness_approval).to be_nil
    expect(AuditLog.all.map { |audit| [audit.before_data, audit.after_data, audit.metadata] }.to_json).not_to include(values[:tin])
  end

  it "blocks edits while check payouts are pending or processing and unlocks after completion" do
    account = create(:connected_account, organization: organization, provider: "check", payout_details: { payee_name: "Island", delivery_method: "pickup" })
    event = create(:event, organization: organization, organizer_profile: profile)
    payout = create(:payout, organization: organization, event: event, connected_account: account,
      settlement: create(:settlement, organization: organization, event: event))
    %w[pending processing].each do |status|
      payout.update!(status: status)
      patch "/api/v1/organizer/tax_information", params: { tax_information: values }, headers: headers
      expect(response).to have_http_status(:unprocessable_entity)
      expect(response.parsed_body["error"]).to include("check payout is in progress")
      get "/api/v1/organizer/tax_information", headers: headers
      expect(response.parsed_body["edit_locked"]).to be(true)
    end
    payout.update!(status: :paid)
    patch "/api/v1/organizer/tax_information", params: { tax_information: values }, headers: headers
    expect(response).to have_http_status(:ok)
  end

  it "requires payout-management permission and does not allow choosing another organization by payload" do
    manager = create(:user)
    create(:organization_membership, organization: organization, user: manager, role: :manager)
    get "/api/v1/organizer/tax_information", headers: auth_headers(manager).merge("X-Organization-Id" => organization.id.to_s)
    expect(response).to have_http_status(:forbidden)
    other = create(:organization)
    patch "/api/v1/organizer/tax_information", params: { tax_information: values.merge(organization_id: other.id) }, headers: headers
    expect(response).to have_http_status(:ok)
    expect(other.organizer_tax_information).to be_nil
    get "/api/v1/organizer/tax_information", headers: auth_headers(owner).merge("X-Organization-Id" => other.id.to_s)
    expect(response).to have_http_status(:forbidden)
  end
end
