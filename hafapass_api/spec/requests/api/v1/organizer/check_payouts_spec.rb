# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Check payout method", type: :request do
  let(:owner) { create(:user, :organizer) }
  let(:profile) { create(:organizer_profile, user: owner) }
  let(:organization) { profile.organization }
  let(:headers) { auth_headers(owner).merge("X-Organization-Id" => organization.id.to_s) }
  let(:details) do
    { payee_name: "Ambros Inc.", delivery_method: "mail", mailing_address: "PO Box 1, Hagåtña, GU 96910",
      memo: "Event proceeds" }
  end

  it "saves a check payee with a plain next step" do
    post "/api/v1/organizer/connected_accounts", params: { provider: "check", payout_details: details }, headers: headers

    expect(response).to have_http_status(:created)
    body = response.parsed_body
    expect(body).to include("provider" => "check", "status" => "onboarding", "payout_ready" => false)
    expect(body["payout_details"]).to include("payee_name" => "Ambros Inc.", "delivery_method" => "mail")
    expect(body["requirements_due"]).to include("payee_details_review")
    expect(body["next_action"]).to include("HåfaPass finance")
  end

  it "requires a payee and a mailing address for mailed checks" do
    post "/api/v1/organizer/connected_accounts",
      params: { provider: "check", payout_details: { payee_name: "", delivery_method: "mail" } }, headers: headers
    expect(response).to have_http_status(:unprocessable_entity)
    expect(response.parsed_body["error"]).to include("name to write on the check", "mailing address")

    post "/api/v1/organizer/connected_accounts",
      params: { provider: "check", payout_details: { payee_name: "Ambros", delivery_method: "pickup",
                                                     pickup_note: "Front desk" } }, headers: headers
    expect(response).to have_http_status(:created)
    expect(response.parsed_body["payout_details"]).not_to have_key("mailing_address")
  end

  it "invalidates an earlier readiness approval when the payee changes" do
    account = create(:connected_account, organization: organization, provider: "check",
      provider_account_id: nil, payout_details: details.stringify_keys)
    expect(account.reload).to be_payout_ready

    patch "/api/v1/organizer/connected_accounts/#{account.id}",
      params: { payout_details: details.merge(payee_name: "Someone Else") }, headers: headers

    expect(response).to have_http_status(:ok)
    expect(account.reload.readiness_revision).to eq(2)
    expect(account).not_to be_payout_ready
    expect(AuditLog.where(action: "connected_account.payout_details_updated", auditable: account)).to exist
  end

  it "keeps legacy accounts' readiness digests unchanged" do
    account = create(:connected_account, organization: organization, provider: "manual", provider_account_id: nil)
    digest = account.provider_configuration_digest
    expect(account.reload.payout_details).to eq({})
    expect(account.provider_configuration_digest).to eq(digest)
    expect(account).to be_payout_ready
  end

  it "is limited to people who manage payouts" do
    manager = create(:user)
    create(:organization_membership, organization: organization, user: manager, role: :manager)
    post "/api/v1/organizer/connected_accounts", params: { provider: "check", payout_details: details },
      headers: auth_headers(manager).merge("X-Organization-Id" => organization.id.to_s)
    expect(response).to have_http_status(:forbidden)

    other = create(:connected_account, provider: "check", provider_account_id: nil,
      payout_details: details.stringify_keys)
    patch "/api/v1/organizer/connected_accounts/#{other.id}", params: { payout_details: details }, headers: headers
    expect(response).to have_http_status(:not_found)
  end
end

RSpec.describe "Recording a check payout", type: :request do
  let(:admin) { create(:user, :admin) }
  let(:organization) { create(:organization) }
  let(:profile) { create(:organizer_profile, organization: organization) }
  let(:event) { create(:event, :completed, organization: organization, organizer_profile: profile) }
  let(:settlement) { create(:settlement, organization: organization, event: event) }
  let(:account) do
    create(:connected_account, organization: organization, provider: "check", provider_account_id: nil,
      payout_details: { "payee_name" => "Ambros Inc.", "delivery_method" => "pickup", "pickup_note" => "Front desk" })
  end
  let!(:payout) do
    create(:payout, organization: organization, event: event, settlement: settlement, connected_account: account,
      status: :processing, provider_payout_id: "manual_po_fixture", created_at: 1.hour.ago,
      payee_snapshot: account.check_payee, payee_approval_digest: account.readiness_state_digest)
  end
  let(:evidence) { { reference: "Check 1042", confirmed_at: 10.minutes.ago.iso8601(6), reason: "Check written" } }

  it "shows who the check is for and records the check number and date" do
    get "/api/v1/admin/payouts", headers: auth_headers(admin)
    listed = response.parsed_body.fetch("payouts").find { |item| item["id"] == payout.id }
    expect(listed).to include("provider" => "check")
    expect(listed["payee"]).to include("payee_name" => "Ambros Inc.", "delivery_method" => "pickup")

    check_date = 10.minutes.ago
    patch "/api/v1/admin/payouts/#{payout.id}", headers: auth_headers(admin), params: {
      status: "paid", provider_payout_id: "Check 1042",
      evidence: { reference: "Check 1042", confirmed_at: check_date.iso8601(6), reason: "Check written and picked up" }
    }
    expect(response).to have_http_status(:ok)
    expect(payout.reload).to have_attributes(status: "paid", provider_payout_id: "Check 1042")
    expect(payout.paid_at).to be_within(1.second).of(check_date)
  end
end

RSpec.describe "Check payee changes while a payout is in flight", type: :request do
  let(:admin) { create(:user, :admin) }
  let(:owner) { create(:user, :organizer) }
  let(:profile) { create(:organizer_profile, user: owner) }
  let(:organization) { profile.organization }
  let(:event) { create(:event, :completed, organization: organization, organizer_profile: profile) }
  let(:account) do
    create(:connected_account, organization: organization, provider: "check", provider_account_id: nil,
      payout_details: { "payee_name" => "Ambros Inc.", "delivery_method" => "mail", "mailing_address" => "PO Box 1" })
  end
  let!(:payout) do
    create(:payout, organization: organization, event: event, connected_account: account,
      settlement: create(:settlement, organization: organization, event: event),
      status: :processing, provider_payout_id: "manual_po_fixture", created_at: 1.hour.ago,
      payee_snapshot: account.check_payee, payee_approval_digest: account.readiness_state_digest)
  end
  let(:paid) do
    { status: "paid", provider_payout_id: "Check 2001",
      evidence: { reference: "Check 2001", confirmed_at: 5.minutes.ago.iso8601(6), reason: "Check mailed" } }
  end

  it "blocks payee edits while a check payout is in flight" do
    patch "/api/v1/organizer/connected_accounts/#{account.id}",
      params: { payout_details: { payee_name: "Someone Else", delivery_method: "mail", mailing_address: "PO Box 9" } },
      headers: auth_headers(owner).merge("X-Organization-Id" => organization.id.to_s)

    expect(response).to have_http_status(:unprocessable_entity)
    expect(response.parsed_body["error"]).to eq(
      "A check payout is in progress. You can change payee details after HåfaPass records it."
    )
    expect(account.reload.check_payee).to include("payee_name" => "Ambros Inc.")

    patch "/api/v1/admin/payouts/#{payout.id}", params: paid, headers: auth_headers(admin)
    expect(response).to have_http_status(:ok)
    expect(payout.reload).to be_status_paid

    patch "/api/v1/organizer/connected_accounts/#{account.id}",
      params: { payout_details: { payee_name: "Someone Else", delivery_method: "mail", mailing_address: "PO Box 9" } },
      headers: auth_headers(owner).merge("X-Organization-Id" => organization.id.to_s)
    expect(response).to have_http_status(:ok)
  end

  it "records a legacy mismatched payee as paid only with explicit confirmation, in the audit evidence" do
    account.update_column(:payout_details, { "payee_name" => "Someone Else", "delivery_method" => "mail",
                                             "mailing_address" => "PO Box 9" })

    get "/api/v1/admin/payouts", headers: auth_headers(admin)
    listed = response.parsed_body.fetch("payouts").find { |item| item["id"] == payout.id }
    expect(listed["payee"]).to include("payee_name" => "Ambros Inc.")
    expect(listed).to include("payee_changed" => true)
    expect(listed["current_payee"]).to include("payee_name" => "Someone Else")

    patch "/api/v1/admin/payouts/#{payout.id}", params: paid, headers: auth_headers(admin)
    expect(response).to have_http_status(:unprocessable_entity)
    expect(response.parsed_body["error"]).to include("Confirm you wrote this check to the approved payee")
    expect(payout.reload).to be_status_processing

    confirmed = paid.deep_merge(evidence: { approved_payee_confirmed: "true" })
    patch "/api/v1/admin/payouts/#{payout.id}", params: confirmed, headers: auth_headers(admin)
    expect(response).to have_http_status(:ok)
    audit = AuditLog.where(auditable: payout, action: "payout.reconciled").last
    expect(audit.metadata.dig("reconciliation", "approved_payee_confirmed")).to be(true)
  end

  it "snapshots the approved payee when PayoutCreator reserves the payout" do
    settlement = create(:settlement, organization: organization, event: event)
    allow(settlement).to receive(:available_to_payout_cents).and_return(500)
    allow(Settlements::Calculator).to receive(:call)
      .and_return(double("calculation", attributes: { source_digest: settlement.source_digest }))
    allow(OrganizationPayoutBalance).to receive(:available_cents).and_return(500)

    record = PayoutCreator.call(settlement: settlement, actor: admin, idempotency_key: "snapshot-test")

    expect(record.payee_snapshot).to eq("payee_name" => "Ambros Inc.", "delivery_method" => "mail", "mailing_address" => "PO Box 1")
    expect(record.payee_approval_digest).to eq(account.readiness_state_digest)
    expect(record).to be_payee_matches_approval
  end

  it "says a duplicate check number is already recorded" do
    other_event = create(:event, :completed, organization: organization, organizer_profile: profile)
    create(:payout, organization: organization, event: other_event, connected_account: account,
      settlement: create(:settlement, organization: organization, event: other_event),
      status: :paid, provider_payout_id: "Check 2001", paid_at: 1.day.ago)

    patch "/api/v1/admin/payouts/#{payout.id}", params: paid, headers: auth_headers(admin)
    expect(response).to have_http_status(:unprocessable_entity)
    expect(response.parsed_body["error"]).to eq("That check number is already recorded")
  end

  it "rejects a check method without a payee or with a malformed payee" do
    headers = auth_headers(owner).merge("X-Organization-Id" => organization.id.to_s)
    account.destroy! if account.payouts.none?
    post "/api/v1/organizer/connected_accounts", params: { provider: "check" }, headers: headers
    expect(response).to have_http_status(:unprocessable_entity)
    post "/api/v1/organizer/connected_accounts", params: { provider: "check", payout_details: "Ambros" }, headers: headers
    expect(response).to have_http_status(:unprocessable_entity)
    expect(response.parsed_body["error"]).to include("who the check is for")
  end
end
