# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Manual payout method approval", type: :request do
  include ActiveSupport::Testing::TimeHelpers

  let(:admin) { create(:user, :admin) }
  let(:profile) { create(:organizer_profile, :verified) }
  let(:organization) { profile.organization }
  let(:owner_headers) { auth_headers(profile.user).merge("X-Organization-Id" => organization.id.to_s) }
  let(:details) { { "payee_name" => "Island Events LLC", "delivery_method" => "mail", "mailing_address" => "PO Box 1, Hagåtña, GU 96910" } }
  let!(:account) do
    ConnectedAccounts::Manager.start!(organization: organization, provider: "check", actor: profile.user, payout_details: details)
  end
  let(:controls) { PaymentReadinessReview::MANUAL_CONTROL_KEYS.index_with(true) }

  def approve(params = {})
    post "/api/v1/admin/connected_accounts/#{account.id}/approve_payout_method", headers: auth_headers(admin), params: {
      controls: controls, expected_digest: PayoutMethodReview.digest(account.reload)
    }.merge(params)
  end

  def queue
    get "/api/v1/admin/dashboard", headers: auth_headers(admin)
    expect(response).to have_http_status(:ok)
    response.parsed_body.fetch("payout_setups_awaiting_approval")
  end

  it "lists only unapproved manual methods newest first with a full count and safe review details" do
    create(:connected_account, organization: organization, provider: "paypal", with_readiness_approval: false, with_tax_information: false)
    newer = ConnectedAccounts::Manager.start!(organization: organization, provider: "manual", actor: profile.user)
    create(:organizer_tax_information, organization: organization)
    ready = create(:connected_account, provider: "check", payout_details: details)
    result = queue
    expect(result["count"]).to eq(2)
    expect(result["items"].pluck("id")).to eq([newer.id, account.id])
    expect(result["items"].pluck("id")).not_to include(ready.id)
    expect(result["items"].last).to include("organization_name" => organization.name, "owner_email" => profile.user.email)
    expect(result["items"].last["tax_information"]).to include("w9_on_file" => true, "masked_tin" => "***-**-5678")
    expect(result.to_json).not_to include("012345678", "tin_digest")
  end

  it "blocks approval until the W-9 is certified without recording provider status or audit evidence" do
    expect(queue["items"].first["payout_review"]).to include("can_approve" => false, "missing" => ["W-9 not certified yet"])
    expect { approve }.not_to change(PaymentReadinessReview, :count)
    expect(response).to have_http_status(:unprocessable_entity)
    expect(response.parsed_body["error"]).to include("W-9 not certified")
    expect(account.reload.charges_enabled).to be(false)
  end

  it "uses one admin action to approve a server-computed immutable snapshot and unlock paid event publishing" do
    tax = create(:organizer_tax_information, organization: organization)
    event = create(:event, organizer_profile: profile, organization: organization)
    create(:ticket_type, event: event, price_cents: 2500)
    post "/api/v1/organizer/events/#{event.id}/publish", headers: owner_headers
    expect(response).to have_http_status(:unprocessable_entity)

    approve(note: "Payee and mailing address reviewed in GU 96910.", evidence_digest: "spoofed")
    expect(response).to have_http_status(:created), response.body
    expect(response.parsed_body.dig("payout_review", "status")).to eq("approved")
    expect(account.reload).to be_payout_ready
    submission, approval = account.payment_readiness_reviews.order(:id).to_a
    expect([submission.decision, approval.decision]).to eq(%w[submission approval])
    expect([submission.actor_user_id, approval.actor_user_id]).to eq([admin.id, admin.id])
    expect(approval.parent_review).to eq(submission)
    expect(approval.review_kind).to eq("manual_payout")
    expect(approval.evidence_digest).to eq(Digest::SHA256.hexdigest(PayoutMethodReview.canonical(approval.reviewed_snapshot).to_json))
    expect(approval.evidence_reference).to include(approval.evidence_digest)
    expect(approval.reviewed_snapshot.to_json).not_to include(tax.tin, "tin_digest", "bank_account_number")
    expect(approval.expires_at.to_date).to eq(Date.current.advance(months: 12))
    expect { approval.update!(reviewed_snapshot: {}) }.to raise_error(ActiveRecord::ReadonlyAttributeError)
    expect(queue["count"]).to eq(0)
    post "/api/v1/organizer/events/#{event.id}/publish", headers: owner_headers
    expect(response).to have_http_status(:ok), response.body
    expect(event.reload).to be_published
    log = AuditLog.find_by!(action: "payout_method.approved", auditable: approval)
    expect(ActivityLogSentence.new(log, actor_name: "Admin").call)
      .to eq("HåfaPass approved the check payout method for #{organization.name}.")
    expect(AuditLog.where(organization: organization).pluck(:action)).to include(
      "connected_account.synced", "payment_readiness.submitted", "payment_readiness.approved", "connected_account.readiness_approved")
    delivery = MessageDelivery.find_by!(template: "payout_method_decision")
    expect(delivery.recipient).to eq(profile.user.email)
    expect(delivery.metadata).to include("decision" => "approval", "note" => "Payee and mailing address reviewed in GU 96910.")
    payload = EmailService.prepare_delivery_payload(delivery)
    expect(payload["html"]).to include("paid tickets can go on sale", "Payee and mailing address reviewed in GU 96910.")
  end

  it "requires every human confirmation, a future valid date and the current reviewed state" do
    create(:organizer_tax_information, organization: organization)
    [{ controls: { payee_matches: true } }, { review_by: "yesterday" }, { review_by: Date.current.iso8601 },
      { expected_digest: "stale" }].each do |invalid|
      expect { approve(invalid) }.not_to change(PaymentReadinessReview, :count)
      expect(response).to have_http_status(invalid.key?(:expected_digest) ? :conflict : :unprocessable_entity), response.body
    end
  end

  it "invalidates approval on payee edits even if reverted, returns to the queue and prevents stale approval" do
    create(:organizer_tax_information, organization: organization)
    approve
    old_digest = PayoutMethodReview.digest(account.reload)
    patch "/api/v1/organizer/connected_accounts/#{account.id}", headers: owner_headers,
      params: { payout_details: details.merge("payee_name" => "Updated payee") }
    expect(response).to have_http_status(:ok)
    expect(account.reload).not_to be_payout_ready
    expect(queue["items"].pluck("id")).to include(account.id)
    approve(expected_digest: old_digest)
    expect(response).to have_http_status(:conflict)
    patch "/api/v1/organizer/connected_accounts/#{account.id}", headers: owner_headers, params: { payout_details: details }
    expect(account.reload).not_to be_payout_ready
  end

  it "invalidates approval when the organizer re-certifies a W-9" do
    create(:organizer_tax_information, organization: organization)
    approve
    expect(account.reload).to be_payout_ready
    patch "/api/v1/organizer/tax_information", headers: owner_headers, params: { tax_information: {
      legal_name: "Updated LLC", tax_classification: "llc_c", tin_type: "ein", tin: "012345678",
      mailing_address: "PO Box 1", signer_name: "Owner", certified: true
    } }
    expect(response).to have_http_status(:ok), response.body
    expect(account.reload).not_to be_payout_ready
    expect(queue["count"]).to eq(1)
  end

  it "records a change request before a W-9 is ready, displays and emails the note, and retains the audit chain" do
    post "/api/v1/admin/connected_accounts/#{account.id}/request_payout_changes", headers: auth_headers(admin),
      params: { expected_digest: PayoutMethodReview.digest(account), note: "Please use the business name from your W-9." }
    expect(response).to have_http_status(:created), response.body
    expect(account.reload).not_to be_payout_ready
    expect(account.payment_readiness_reviews.order(:id).pluck(:decision)).to eq(%w[submission rejection])
    get "/api/v1/organizer/connected_accounts", headers: owner_headers
    expect(response.parsed_body.first["payout_review"]).to include("status" => "changes_requested", "note" => "Please use the business name from your W-9.")
    expect(AuditLog.where(action: "payout_method.changes_requested", organization: organization)).to exist
    delivery = MessageDelivery.find_by!(template: "payout_method_decision")
    payload = EmailService.prepare_delivery_payload(delivery)
    expect(payload["html"]).to include("Please use the business name", "Please update your payout details")
  end

  it "revokes an active approval when asking for changes and refuses empty or sensitive notes" do
    create(:organizer_tax_information, organization: organization)
    approve
    ["", "Account 123456789123", "Account 1234.5678.9012", "Account 1234/5678/9012", "TIN 012345678"].each do |note|
      post "/api/v1/admin/connected_accounts/#{account.id}/request_payout_changes", headers: auth_headers(admin),
        params: { expected_digest: PayoutMethodReview.digest(account.reload), note: note }
      expect(response).to have_http_status(:unprocessable_entity)
      expect(account.reload).to be_payout_ready
    end
    post "/api/v1/admin/connected_accounts/#{account.id}/request_payout_changes", headers: auth_headers(admin),
      params: { expected_digest: PayoutMethodReview.digest(account.reload), note: "Please clarify the mailing address." }
    expect(response).to have_http_status(:created)
    expect(account.reload).not_to be_payout_ready
    expect(account.payment_readiness_reviews.order(:id).pluck(:decision)).to eq(%w[submission approval revocation submission rejection])
  end

  it "returns an expired approval to the queue without destroying its history" do
    create(:organizer_tax_information, organization: organization)
    approve(review_by: 1.day.from_now.to_date.iso8601)
    expect(account.reload).to be_payout_ready
    travel_to 3.days.from_now do
      expect(account.reload).not_to be_payout_ready
      expect(queue["items"].pluck("id")).to include(account.id)
    end
    expect(account.payment_readiness_reviews.count).to eq(2)
  end

  it "restricts both actions to admins and keeps provider-integrated accounts on the detailed evidence path" do
    %w[approve_payout_method request_payout_changes].each do |action|
      post "/api/v1/admin/connected_accounts/#{account.id}/#{action}", headers: owner_headers, params: { note: "Fix this" }
      expect(response).to have_http_status(:forbidden)
      post "/api/v1/admin/connected_accounts/#{account.id}/#{action}"
      expect(response).to have_http_status(:unauthorized)
    end
    other = create(:connected_account, provider: "paypal", with_readiness_approval: false, with_tax_information: false)
    post "/api/v1/admin/connected_accounts/#{other.id}/approve_payout_method", headers: auth_headers(admin), params: { controls: controls }
    expect(response).to have_http_status(:unprocessable_entity)
    expect(other.payment_readiness_reviews).to be_empty
  end

  it "rolls back provider status, reviews and audits together on an audit write failure" do
    create(:organizer_tax_information, organization: organization)
    allow(AuditLogger).to receive(:record!).and_call_original
    allow(AuditLogger).to receive(:record!).with(hash_including(action: "payout_method.approved")).and_raise(AuditLogger::WriteError)
    expect { approve }.to raise_error(AuditLogger::WriteError)
    expect(account.reload.charges_enabled).to be(false)
    expect(account.payment_readiness_reviews).to be_empty
    expect(AuditLog.where(action: "connected_account.synced", auditable: account)).not_to exist
    expect(MessageDelivery.where(template: "payout_method_decision")).to be_empty
  end
end
