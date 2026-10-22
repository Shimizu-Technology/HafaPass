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

  it "rejects creating a check method without a payee or with a malformed payee" do
    expect(organization.connected_accounts).to be_empty
    post "/api/v1/organizer/connected_accounts", params: { provider: "check" }, headers: headers
    expect(response).to have_http_status(:unprocessable_entity)
    expect(response.parsed_body["error"]).to include("who the check is for")
    post "/api/v1/organizer/connected_accounts", params: { provider: "check", payout_details: "Ambros" }, headers: headers
    expect(response).to have_http_status(:unprocessable_entity)
    expect(organization.connected_accounts.reload).to be_empty
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
  let(:evidence) { { reference: "Check 1042", confirmed_at: 10.minutes.ago.iso8601(6), reason: "Check written", actual_check_amount_cents: 100 } }

  it "shows who the check is for and records the check number and date" do
    get "/api/v1/admin/payouts", headers: auth_headers(admin)
    listed = response.parsed_body.fetch("payouts").find { |item| item["id"] == payout.id }
    expect(listed).to include("provider" => "check")
    expect(listed["payee"]).to include("payee_name" => "Ambros Inc.", "delivery_method" => "pickup")

    check_date = 10.minutes.ago
    patch "/api/v1/admin/payouts/#{payout.id}", headers: auth_headers(admin), params: {
      status: "paid", provider_payout_id: "Check 1042",
      evidence: { reference: "Check 1042", confirmed_at: check_date.iso8601(6), reason: "Check written and picked up", actual_check_amount_cents: 100 }
    }
    expect(response).to have_http_status(:ok)
    expect(payout.reload).to have_attributes(status: "paid", provider_payout_id: "Check 1042")
    expect(payout.paid_at).to be_within(1.second).of(check_date)
  end

  it "preserves a $100 issued check and collects late backup withholding from the next payout" do
    issued = create(:payout, organization: organization, event: event, settlement: settlement,
      connected_account: account, amount_cents: 10_000, status: :processing,
      provider_payout_id: "manual_po_issued", created_at: 1.hour.ago,
      payee_snapshot: account.check_payee, payee_approval_digest: account.readiness_state_digest)
    tax = organization.organizer_tax_information
    tax.update!(backup_withholding_flag: true, backup_withholding_reason: "IRS withholding notice")
    SiteSetting.instance.update!(backup_withholding_mode: "withhold")

    patch "/api/v1/admin/payouts/#{issued.id}", headers: auth_headers(admin), params: {
      status: "paid", provider_payout_id: "Check 1042",
      evidence: evidence.merge(actual_check_amount_cents: 10_000, approved_tax_payee_confirmed: true)
    }
    expect(response).to have_http_status(:ok)
    expect(issued.reload).to have_attributes(amount_cents: 10_000, withheld_cents: 0,
      under_withheld_cents: 2400)
    expect(issued.disbursement_cents).to eq(10_000)
    expect(PayeeWithholdingBalance.for_tax(tax)).to eq(2400)

    next_payout = create(:payout, organization: organization, event: event, settlement: settlement,
      connected_account: account, amount_cents: 10_000, status: :pending,
      payee_snapshot: account.check_payee, payee_approval_digest: account.readiness_state_digest)
    organization.with_lock do
      next_payout.with_lock { PayoutWithholdingGuard.call(payout: next_payout, actor: admin) }
    end
    expect(next_payout.reload).to have_attributes(withheld_cents: 2400, carried_withholding_cents: 2400)
    expect(next_payout.disbursement_cents).to eq(5200)
    expect(AuditLog.where(auditable: issued, action: "payout.under_withholding_carried")).to exist
    expect(AuditLog.where(auditable: next_payout, action: "payout.backup_withholding_recalculated")).to exist
    PayoutReconciler.call(payout: next_payout, actor: admin, status: "failed",
      evidence: { reference: "Check voided", confirmed_at: Time.current.iso8601(6),
        reason: "Check voided before disbursement" })

    small_payout = create(:payout, organization: organization, event: event, settlement: settlement,
      connected_account: account, amount_cents: 2000, status: :pending,
      payee_snapshot: account.check_payee, payee_approval_digest: account.readiness_state_digest)
    organization.with_lock do
      small_payout.with_lock { PayoutWithholdingGuard.call(payout: small_payout, actor: admin) }
    end
    expect(small_payout.reload).to have_attributes(withheld_cents: 480, carried_withholding_cents: 1520)
    expect(small_payout.disbursement_cents).to eq(0)
    small_payout.update!(status: :processing)
    PayoutReconciler.call(payout: small_payout, actor: admin, status: "paid",
      provider_payout_id: "withholding_only_#{small_payout.id}",
      evidence: { reference: "Withholding ledger entry", confirmed_at: Time.current.iso8601(6),
        reason: "No check was due after withholding", actual_check_amount_cents: 0 })
    expect(small_payout.reload).to be_status_paid
    expect(PayeeWithholdingBalance.for_tax(tax)).to eq(880)
    expect(AuditLog.where(auditable: small_payout, action: "payout.under_withholding_collected")).to exist
    report = AnnualPayeeReport.new(organization: organization, year: Time.current.in_time_zone("Pacific/Guam").year,
      payee_key: AnnualPayeeReport.payee_key_for(issued))
    expect(report.row).to include(withheld_cents: 2000, net_disbursed_cents: 10_000)
  end

  it "reverses a paid check without changing its carry and excludes that carry from annual withholding" do
    tax = organization.organizer_tax_information
    issued = create(:payout, organization: organization, event: event, settlement: settlement,
      connected_account: account, status: :paid, amount_cents: 10_000, under_withheld_cents: 2400,
      paid_at: Time.current, payee_snapshot: account.check_payee)
    carrying = create(:payout, organization: organization, event: event, settlement: settlement,
      connected_account: account, amount_cents: 10_000,
      payee_snapshot: account.check_payee, payee_approval_digest: account.readiness_state_digest)
    organization.with_lock do
      carrying.with_lock { PayoutWithholdingGuard.call(payout: carrying, actor: admin) }
    end
    carrying.update!(status: :processing)
    PayoutReconciler.call(payout: carrying, actor: admin, status: "paid", provider_payout_id: "Check 1043",
      evidence: { reference: "Check 1043", confirmed_at: Time.current.iso8601(6),
        reason: "Check disbursed", actual_check_amount_cents: 7600 })
    year = Time.current.in_time_zone("Pacific/Guam").year
    key = AnnualPayeeReport.payee_key_for(issued)
    report = -> { AnnualPayeeReport.new(organization: organization, year: year, payee_key: key).row }
    expect(PayeeWithholdingBalance.for_tax(tax)).to eq(0)
    expect(report.call[:withheld_cents]).to eq(2400)

    PayoutReconciler.call(payout: carrying, actor: admin, status: "reversed", provider_payout_id: "Check 1043",
      evidence: { reference: "Bank reversal", confirmed_at: Time.current.iso8601(6),
        reason: "Check was returned" })

    expect(carrying.reload).to have_attributes(status: "reversed", under_withheld_cents: 0,
      carried_withholding_cents: 2400, withheld_cents: 0)
    expect(PayeeWithholdingBalance.for_tax(tax)).to eq(2400)
    expect(report.call[:withheld_cents]).to eq(0)
  end

  it "preserves a paid check's under-withheld amount on reversal" do
    tax = organization.organizer_tax_information
    issued = create(:payout, organization: organization, event: event, settlement: settlement,
      connected_account: account, amount_cents: 10_000, status: :processing,
      payee_snapshot: account.check_payee, payee_approval_digest: account.readiness_state_digest)
    tax.update!(backup_withholding_flag: true, backup_withholding_reason: "IRS review")
    PayoutReconciler.call(payout: issued, actor: admin, status: "paid", provider_payout_id: "Check 1044",
      evidence: { reference: "Check 1044", confirmed_at: Time.current.iso8601(6),
        reason: "Check disbursed", actual_check_amount_cents: 10_000, approved_tax_payee_confirmed: true })
    expect(issued.reload.under_withheld_cents).to eq(2400)

    PayoutReconciler.call(payout: issued, actor: admin, status: "reversed", provider_payout_id: "Check 1044",
      evidence: { reference: "Bank reversal", confirmed_at: Time.current.iso8601(6),
        reason: "Check was returned" })

    expect(issued.reload).to have_attributes(status: "reversed", under_withheld_cents: 2400,
      amount_cents: 10_000, withheld_cents: 0)
  end

  it "rejects a check amount mismatch until an admin records a reasoned audited adjustment" do
    mismatched = evidence.merge(actual_check_amount_cents: 99)
    patch "/api/v1/admin/payouts/#{payout.id}", headers: auth_headers(admin), params: {
      status: "paid", provider_payout_id: "Check 1042", evidence: mismatched
    }
    expect(response).to have_http_status(:unprocessable_content)
    expect(response.parsed_body.fetch("error")).to include("Actual check amount does not match")
    expect(payout.reload).to have_attributes(status: "processing", withheld_cents: 0)
    expect(payout.payout_check_adjustments).to be_empty

    post "/api/v1/admin/payouts/#{payout.id}/check_amount_adjustment", headers: auth_headers(admin), params: {
      actual_check_amount_cents: 99, reason: "Check register shows a one cent error"
    }
    expect(response).to have_http_status(:ok)
    expect(payout.payout_check_adjustments.last.amount_cents).to eq(-1)
    expect(AuditLog.where(auditable: payout, action: "payout.check_amount_adjusted")).to exist

    patch "/api/v1/admin/payouts/#{payout.id}", headers: auth_headers(admin), params: {
      status: "paid", provider_payout_id: "Check 1042", evidence: mismatched
    }
    expect(response).to have_http_status(:ok)
    expect(payout.reload.disbursement_cents).to eq(100)
    expect(payout.confirmed_check_amount_cents).to eq(99)
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
      evidence: { reference: "Check 2001", confirmed_at: 5.minutes.ago.iso8601(6), reason: "Check mailed", actual_check_amount_cents: 100 } }
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

    confirmed = paid.deep_merge(evidence: { approved_payee_confirmed: "true", approved_tax_payee_confirmed: "true" })
    patch "/api/v1/admin/payouts/#{payout.id}", params: confirmed, headers: auth_headers(admin)
    expect(response).to have_http_status(:ok)
    audit = AuditLog.where(auditable: payout, action: "payout.reconciled").last
    expect(audit.metadata.dig("reconciliation", "approved_payee_confirmed")).to be(true)
    expect(audit.metadata.dig("reconciliation", "approved_tax_payee_confirmed")).to be(true)
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
    expect(record.tax_information_snapshot).to include("legal_name" => "Island Events LLC",
      "masked_tin" => "***-**-5678", "tin_last_four" => "5678",
      "tax_information_id" => organization.organizer_tax_information.id)
    expect(record.tax_information_tin).to eq("012345678")
    expect(record.read_attribute_before_type_cast(:tax_information_tin)).not_to include("012345678")
    expect(record.to_json).not_to include("012345678")
    expect(AuditLog.where(auditable: record).map(&:metadata).to_json).not_to include("012345678")
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
end
