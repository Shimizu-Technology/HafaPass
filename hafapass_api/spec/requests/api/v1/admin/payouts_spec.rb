require "rails_helper"

RSpec.describe "Evidence-backed payout reconciliation", type: :request do
  let(:admin) { create(:user, :admin) }
  let(:organization) { create(:organization) }
  let(:profile) { create(:organizer_profile, organization: organization) }
  let(:event) { create(:event, :completed, organization: organization, organizer_profile: profile) }
  let(:settlement) { create(:settlement, organization: organization, event: event) }
  let(:account) { create(:connected_account, organization: organization, provider: "manual") }
  let!(:payout) do
    create(:payout, organization: organization, event: event, settlement: settlement,
      connected_account: account, status: :processing, provider_payout_id: "manual_po_fixture", created_at: 1.hour.ago)
  end
  let(:evidence) { { reference: "bank-confirmation/fixture", confirmed_at: 1.minute.ago.iso8601(6), reason: "Matched bank confirmation and payout cents" } }
  let(:payload) { { status: "paid", provider_payout_id: "bank_transfer_fixture", evidence: evidence } }

  def reconcile(attributes = payload, actor: admin)
    patch "/api/v1/admin/payouts/#{payout.id}", params: attributes, headers: auth_headers(actor)
  end

  it "routes admin payout requests through the idempotency gate" do
    post "/api/v1/admin/payouts", params: { settlement_id: settlement.id }, headers: auth_headers(admin)
    expect(response).to have_http_status(:unprocessable_entity)
    expect(response.parsed_body.fetch("error")).to include("Idempotency-Key")

    post "/api/v1/admin/payouts", params: { settlement_id: settlement.id }, headers: auth_headers(create(:user))
    expect(response).to have_http_status(:forbidden)
  end

  it "exposes a release-hold action and rejects a stale payout above current payable" do
    payout.update!(status: :held, held_from_status: "processing")
    post "/api/v1/admin/payouts/#{payout.id}/release_hold", headers: auth_headers(admin)
    expect(response).to have_http_status(:unprocessable_content)
    expect(response.parsed_body.fetch("error")).to include("cancel and reissue")
    expect(payout.reload).to be_status_held
  end

  it "releases an affordable hold to its recorded prior status and audits the admin" do
    payout.update!(status: :held, held_from_status: "processing")
    create(:balance_adjustment, organization: organization, event: event, amount_cents: 1000)

    post "/api/v1/admin/payouts/#{payout.id}/release_hold", headers: auth_headers(admin)

    expect(response).to have_http_status(:ok)
    expect(payout.reload).to have_attributes(status: "processing", held_from_status: nil)
    expect(AuditLog.find_by!(auditable: payout, action: "payout.released_from_cancellation_hold").actor_user).to eq(admin)
  end

  it "requires evidence before changing a payout or releasing its reservation" do
    %w[paid failed reversed].each do |status|
      reconcile({ status: status })
      expect(response).to have_http_status(:unprocessable_content)
      expect(payout.reload).to be_status_processing
    end
    expect(AuditLog.where(auditable: payout)).not_to exist
  end

  it "rejects simulated or placeholder identifiers as proof of a paid transfer" do
    [nil, "manual_po_fixture", "sim_po_fixture"].each do |identifier|
      reconcile(payload.merge(provider_payout_id: identifier))
      expect(response).to have_http_status(:unprocessable_content)
      expect(payout.reload).to be_status_processing
    end
  end

  it "records the confirmed outcome and append-only evidence with its actor" do
    reconcile
    expect(response).to have_http_status(:ok)
    expect(payout.reload).to have_attributes(status: "paid", provider_payout_id: "bank_transfer_fixture",
      paid_at: Time.iso8601(evidence[:confirmed_at]))
    audit = AuditLog.find_by!(auditable: payout, action: "payout.reconciled")
    expect(audit.actor_user).to eq(admin)
    expect(audit.metadata.fetch("reconciliation")).to eq(evidence.stringify_keys)
    expect(audit.before_data.fetch("status")).to eq("processing")
    expect(audit.after_data.fetch("status")).to eq("paid")
  end

  it "shows cancelled-event buyer liability and requires already-sent evidence through the API" do
    order = create(:order, event: event)
    create(:payment, :succeeded, order: order, provider_environment: "live")
    event.update!(status: :cancelled)
    EventCancellationRefunds.prepare!(event: event, actor: admin)
    get "/api/v1/admin/payouts", params: { event_id: event.id }, headers: auth_headers(admin)
    expect(response.parsed_body.fetch("payouts").first).to include(
      "status" => "held", "outstanding_buyer_balance_cents" => 5250)

    reconcile
    expect(response).to have_http_status(:unprocessable_content)
    expect(response.parsed_body.fetch("error")).to include("already sent before the cancellation")
    reconcile(payload.merge(evidence: evidence.merge(sent_before_cancellation_confirmed: true,
      cancellation_payout_reason: "Transfer cleared before cancellation notice")))
    expect(response).to have_http_status(:ok)
    expect(payout.reload).to be_status_paid
    get "/api/v1/admin/payouts", params: { event_id: event.id }, headers: auth_headers(admin)
    expect(response.parsed_body.fetch("payouts").first).to include(
      "status" => "paid", "outstanding_buyer_balance_cents" => 5250)
  end

  it "calculates a held event's payable amount once per listing request" do
    payout.update!(status: :held, held_from_status: :processing)
    create(:payout, organization: organization, event: event, settlement: settlement,
      connected_account: account, status: :held, held_from_status: :processing,
      provider_payout_id: "manual_po_second")
    other_event = create(:event, :completed, organization: organization, organizer_profile: profile)
    create(:payout, organization: organization, event: other_event,
      settlement: create(:settlement, organization: organization, event: other_event),
      connected_account: account, status: :held, held_from_status: :processing,
      provider_payout_id: "manual_po_other_event")
    allow(Settlements::Calculator).to receive(:call).and_call_original

    get "/api/v1/admin/payouts", headers: auth_headers(admin)

    expect(response).to have_http_status(:ok)
    expect(response.parsed_body.fetch("payouts").count).to eq(3)
    expect(Settlements::Calculator).to have_received(:call).with(event).once
    expect(Settlements::Calculator).to have_received(:call).with(other_event).once

    get "/api/v1/admin/payouts", headers: auth_headers(admin)
    expect(Settlements::Calculator).to have_received(:call).with(event).twice
    expect(Settlements::Calculator).to have_received(:call).with(other_event).twice
  end

  it "recovers the exact same outcome without creating another audit or changing evidence" do
    2.times { reconcile; expect(response).to have_http_status(:ok) }
    expect(AuditLog.where(auditable: payout, action: "payout.reconciled").count).to eq(1)
    reconcile(payload.merge(evidence: evidence.merge(reference: "a-different-receipt")))
    expect(response).to have_http_status(:unprocessable_content)
    expect(AuditLog.where(auditable: payout).count).to eq(1)
  end

  it "rolls the payout back when its audit cannot be recorded" do
    invalid_audit = AuditLog.new
    invalid_audit.errors.add(:base, "Fixture audit unavailable")
    allow(AuditLogger).to receive(:record!).and_raise(ActiveRecord::RecordInvalid.new(invalid_audit))
    reconcile
    expect(response).to have_http_status(:unprocessable_content)
    expect(payout.reload).to have_attributes(status: "processing", paid_at: nil, provider_payout_id: "manual_po_fixture")
  end

  it "retains the original transfer identity when recording a confirmed reversal" do
    reconcile
    reversed = payload.merge(status: "reversed", evidence: evidence.merge(reference: "bank-reversal/fixture"))
    reconcile(reversed.merge(provider_payout_id: "replacement-transfer"))
    expect(response).to have_http_status(:unprocessable_content)
    expect(payout.reload).to be_status_paid
    reconcile(reversed)
    expect(response).to have_http_status(:ok)
    expect(payout.reload).to have_attributes(status: "reversed", provider_payout_id: "bank_transfer_fixture")
    expect(AuditLog.where(auditable: payout, action: "payout.reconciled").count).to eq(2)
  end

  it "rejects unzoned, future and pre-request confirmation timestamps" do
    ["2026-01-01T12:00:00", 1.hour.from_now.iso8601, 2.hours.ago.iso8601].each do |timestamp|
      reconcile(payload.merge(evidence: evidence.merge(confirmed_at: timestamp)))
      expect(response).to have_http_status(:unprocessable_content)
      expect(payout.reload).to be_status_processing
    end
  end

  it "requires acknowledgment of the latest conflict and retains that acknowledgment on retry" do
    payout.update!(failure_code: "provider_result_conflict")
    conflict = AuditLogger.record!(action: "payout.provider_result_conflict", auditable: payout, actor: admin)
    reconcile
    expect(response).to have_http_status(:unprocessable_content)
    expect(response.parsed_body.fetch("conflict_audit_id")).to eq(conflict.id)
    expect(payout.reload).to be_status_processing
    reconcile(payload.merge(evidence: evidence.merge(conflict_audit_id: conflict.id + 1)))
    expect(response).to have_http_status(:unprocessable_content)
    2.times do
      reconcile(payload.merge(evidence: evidence.merge(conflict_audit_id: conflict.id)))
      expect(response).to have_http_status(:ok)
    end
    expect(payout.reload).to have_attributes(status: "paid", failure_code: nil)
    expect(AuditLog.where(auditable: payout, action: "payout.reconciled").count).to eq(1)
  end

  it "refuses ordinary organizer access even with well-formed confirmation evidence" do
    reconcile(payload, actor: profile.user)
    expect(response).to have_http_status(:forbidden)
    expect(payout.reload).to be_status_processing
  end

  it "requires audited confirmation after approval changes, while failed remains available" do
    account.increment!(:readiness_revision)
    get "/api/v1/admin/payouts", headers: auth_headers(admin)
    listed = response.parsed_body.fetch("payouts").find { |item| item["id"] == payout.id }
    expect(listed).to include("tax_approval_changed" => true)
    expect(listed.dig("tax_information_snapshot", "masked_tin")).to eq("***-**-5678")
    expect(response.body).not_to include("012345678")

    reconcile
    expect(response).to have_http_status(:unprocessable_content)
    expect(response.parsed_body["error"]).to include("Confirm this payout was already sent")
    expect(payout.reload).to be_status_processing

    reconcile(payload.merge(evidence: evidence.merge(approved_tax_payee_confirmed: true)))
    expect(response).to have_http_status(:ok)
    audit = AuditLog.find_by!(auditable: payout, action: "payout.reconciled")
    expect(audit.metadata.dig("reconciliation", "approved_tax_payee_confirmed")).to be(true)
    expect(audit.metadata.to_json).not_to include("012345678")
  end

  it "requires actual payee and evidence for a legacy paid payout, but allows failure" do
    Payout.where(id: payout.id).update_all(tax_information_snapshot: {}, tax_information_tin: nil, tax_approval_digest: nil)
    payout.reload
    reconcile
    expect(response).to have_http_status(:unprocessable_content)
    reconcile(payload.merge(evidence: evidence.merge(approved_tax_payee_confirmed: true)))
    expect(response).to have_http_status(:unprocessable_content)
    legacy = evidence.merge(legacy_payee_name: "  Actual Guam Payee  ", legacy_evidence_note: "  Check 1042  ", legacy_payee_confirmed: true)
    reconcile(payload.merge(evidence: legacy.merge(legacy_evidence_note: " ")))
    expect(response).to have_http_status(:unprocessable_content)
    reconcile(payload.merge(evidence: legacy.merge(legacy_payee_confirmed: false)))
    expect(response).to have_http_status(:unprocessable_content)
    reconcile(payload.merge(evidence: legacy.merge(approved_tax_payee_confirmed: true)))
    expect(response).to have_http_status(:unprocessable_content)
    reconcile(payload.merge(status: "failed", evidence: evidence))
    expect(response).to have_http_status(:ok)
    expect(payout.reload).to be_status_failed
  end

  it "records the entered legacy payee and reference in append-only audit evidence" do
    Payout.where(id: payout.id).update_all(tax_information_snapshot: {}, tax_information_tin: nil, tax_approval_digest: nil)
    legacy = evidence.merge(legacy_payee_name: " Actual Guam Payee ", legacy_evidence_note: " Check 1042 ", legacy_payee_confirmed: true)
    reconcile(payload.merge(evidence: legacy))
    expect(response).to have_http_status(:ok)
    expect(AuditLog.find_by!(auditable: payout, action: "payout.reconciled").metadata.fetch("reconciliation"))
      .to include("legacy_payee_name" => "Actual Guam Payee", "legacy_evidence_note" => "Check 1042", "legacy_payee_confirmed" => true)
  end

  it "does not attach legacy payee evidence to a payout with a W-9 snapshot" do
    reconcile(payload.merge(evidence: evidence.merge(legacy_payee_name: "Other Payee", legacy_evidence_note: "Check 1042", legacy_payee_confirmed: true)))
    expect(response).to have_http_status(:unprocessable_content)
    expect(payout.reload).to be_status_processing
  end
end
