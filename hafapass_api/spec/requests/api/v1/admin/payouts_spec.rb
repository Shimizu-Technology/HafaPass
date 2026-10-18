require "rails_helper"

RSpec.describe "Evidence-backed payout reconciliation", type: :request do
  let(:admin) { create(:user, :admin) }
  let(:organization) { create(:organization) }
  let(:profile) { create(:organizer_profile, organization: organization) }
  let(:event) { create(:event, :completed, organization: organization, organizer_profile: profile) }
  let(:settlement) { create(:settlement, organization: organization, event: event) }
  let(:account) { create(:connected_account, organization: organization, provider: "manual", with_readiness_approval: false) }
  let!(:payout) do
    create(:payout, organization: organization, event: event, settlement: settlement,
      connected_account: account, status: :processing, provider_payout_id: "manual_po_fixture", created_at: 1.hour.ago)
  end
  let(:evidence) { { reference: "bank-confirmation/fixture", confirmed_at: 1.minute.ago.iso8601(6), reason: "Matched bank confirmation and payout cents" } }
  let(:payload) { { status: "paid", provider_payout_id: "bank_transfer_fixture", evidence: evidence } }

  def reconcile(attributes = payload, actor: admin)
    patch "/api/v1/admin/payouts/#{payout.id}", params: attributes, headers: auth_headers(actor)
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

  it "refuses ordinary organizer access even with well-formed confirmation evidence" do
    reconcile(payload, actor: profile.user)
    expect(response).to have_http_status(:forbidden)
    expect(payout.reload).to be_status_processing
  end
end
