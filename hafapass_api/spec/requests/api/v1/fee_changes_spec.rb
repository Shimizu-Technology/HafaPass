# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Scheduled fee changes", type: :request do
  include ActiveSupport::Testing::TimeHelpers
  let(:admin) { create(:user, :admin) }
  let(:profile) { create(:organizer_profile, :verified) }
  let!(:event) { create(:event, :published, organizer_profile: profile, starts_at: 50.days.from_now) }
  let!(:ticket) { create(:ticket_type, event: event, price_cents: 2500, quantity_available: 20) }
  let(:effective_at) { 31.days.from_now.iso8601 }

  before do
    PlatformCapabilityReviews::Manager.quick_approve!(capability: "policy_register", actor: admin,
      draft_policies_acknowledged: true)
  end

  def schedule(attributes = {})
    payload = {
      service_fee_percent: 7, service_fee_flat_cents: 150, effective_at: effective_at,
      future_terms_approved: true, draft_policies_acknowledged: true
    }.merge(attributes)
    get "/api/v1/admin/settings/fee_change_preview", params: payload.slice(:service_fee_percent, :service_fee_flat_cents),
      headers: auth_headers(admin)
    patch "/api/v1/admin/settings", params: payload.merge(
      approved_registry_digest: payload[:approved_registry_digest] || response.parsed_body.fetch("registry_digest")),
      headers: auth_headers(admin)
  end

  it "previews affected organizations and enforces the configurable notice period" do
    create(:event, starts_at: 60.days.from_now) # a future draft is affected
    old = create(:event, :completed)
    get "/api/v1/admin/settings/fee_change_preview", headers: auth_headers(admin)
    expect(response.parsed_body).to include("affected_organizer_count" => 2, "owner_email_count" => 2,
      "minimum_notice_days" => 30, "unreachable_organization_ids" => [])

    schedule(effective_at: 29.days.from_now.iso8601)
    expect(response).to have_http_status(:unprocessable_content)
    expect(FeeChange).not_to exist
    SiteSetting.instance.update!(fee_notice_days: 45)
    schedule
    expect(response).to have_http_status(:unprocessable_content)
    expect(old.reload).to be_completed
  end

  it "notifies the owner, preserves old checkout fees until activation, and snapshots new fees afterward" do
    schedule
    expect(response).to have_http_status(:ok)
    change = FeeChange.sole
    expect(ActiveJob::Base.queue_adapter.enqueued_jobs).to include(
      a_hash_including(job: ActivateFeeChangeJob, at: Time.iso8601(effective_at).to_f))
    expect(change.preapproval).to be_decision_approval
    expect(change.preapproved_registry_digest).to eq(PolicyRegistry.registry_digest(material_terms: change.new_terms))
    notice = change.notices.sole
    expect(notice).to have_attributes(organization: profile.organization, owner: profile.user)
    expect(MessageDelivery.find_by!(template: "fee_change_notice")).to have_attributes(recipient: profile.user.email)
    payload = EmailService.prepare_delivery_payload(MessageDelivery.find_by!(template: "fee_change_notice"))
    expect(payload.fetch("html")).to include("5.0%", "7.0%", "$27.25", "$28.25", "Orders placed before")
    expect(AuditLog.where(action: "site_settings.fee_terms_scheduled")).to exist
    expect(SiteSetting.instance.service_fee_percent).to eq(5)

    get "/api/v1/events/#{event.slug}"
    before_price = response.parsed_body.fetch("ticket_types").sole.fetch("all_in_price_cents")
    expect(before_price).to eq(2725)

    travel_to(Time.iso8601(effective_at) + 1.second) do
      get "/api/v1/events/#{event.slug}"
      after_price = response.parsed_body.fetch("ticket_types").sole.fetch("all_in_price_cents")
      expect(after_price).to eq(2825)
      post "/api/v1/orders", params: { event_id: event.id, buyer_email: "stale@example.test",
        buyer_name: "Stale Buyer", terms_accepted: true, terms_version: PolicyRegistry.buyer_terms[:version],
        line_items: [{ ticket_type_id: ticket.id, quantity: 1 }], expected_total_cents: before_price }
      expect(response).to have_http_status(:unprocessable_content)
      expect(response.parsed_body).to include("code" => "price_changed")
      expect(Order.where(buyer_email: "stale@example.test")).not_to exist
      order = Commerce::OrderCreator.call(event: event, line_items: [{ ticket_type_id: ticket.id, quantity: 2 }],
        buyer_email: "fee@example.test", buyer_name: "Fee Buyer", payment_required: false,
        expected_total_cents: 2 * after_price).order
      expect(order.total_cents).to eq(2 * after_price)
      expect(order.service_fee_cents).to eq(650)
      expect(order.fee_policy_snapshot).to eq("buyer_pays")
      expect(change.reload.activated_at).to be_present
      expect(AuditLog.where(action: "site_settings.fee_terms_activated")).to exist
      expect(PlatformCapabilities.active_approval("policy_register")).to eq(change.preapproval)
    end
  end

  it "keeps the old approval through activation and switches the approval atomically with fees" do
    old_approval = PlatformCapabilities.active_approval("policy_register")
    schedule
    change = FeeChange.sole
    free_ticket = create(:ticket_type, event: event, price_cents: 0, quantity_available: 2)
    allow(Rails.env).to receive(:production?).and_return(true)
    expect(PlatformCapabilities.active_approval("policy_register")).to eq(old_approval)
    expect(PlatformCapabilities.enabled?("policy_register")).to be(true)
    post "/api/v1/orders", params: { event_id: event.id, buyer_email: "before@example.test",
      buyer_name: "Before", terms_accepted: true, terms_version: PolicyRegistry.buyer_terms[:version],
      line_items: [{ ticket_type_id: free_ticket.id, quantity: 1 }], expected_total_cents: 0 }
    expect(response).to have_http_status(:created)
    travel_to(Time.iso8601(effective_at)) do
      ActivateFeeChangeJob.perform_now(change.id)
      expect(SiteSetting.instance.service_fee_percent).to eq(7)
      expect(PlatformCapabilities.active_approval("policy_register")).to eq(change.preapproval)
      expect(PlatformCapabilities.enabled?("policy_register")).to be(true)
      post "/api/v1/orders", params: { event_id: event.id, buyer_email: "after@example.test",
        buyer_name: "After", terms_accepted: true, terms_version: PolicyRegistry.buyer_terms[:version],
        line_items: [{ ticket_type_id: free_ticket.id, quantity: 1 }], expected_total_cents: 0 }
      expect(response).to have_http_status(:created)
      ActivateFeeChangeJob.perform_now(change.id)
      expect(AuditLog.where(action: "site_settings.fee_terms_activated").count).to eq(1)
    end
  end

  it "blocks changed policy text and alerts the admin without changing fees or approval" do
    old_approval = PlatformCapabilities.active_approval("policy_register")
    schedule
    change = FeeChange.sole
    allow(PolicyRegistry).to receive(:registry_digest).and_call_original
    allow(PolicyRegistry).to receive(:registry_digest).with(material_terms: change.new_terms).and_return("f" * 64)
    travel_to(Time.iso8601(effective_at)) do
      ActivateFeeChangeJob.perform_now(change.id)
      expect(change.reload.blocked_at).to be_present
      expect(SiteSetting.first!.service_fee_percent).to eq(5)
      expect(PlatformCapabilities.active_approval("policy_register")).to eq(old_approval)
      get "/api/v1/admin/settings", headers: auth_headers(admin)
      expect(response.parsed_body.dig("blocked_fee_change", "activation_error")).to include("no longer matches")
      expect(AuditLog.where(action: "site_settings.fee_terms_activation_blocked").count).to eq(1)
      ActivateFeeChangeJob.perform_now(change.id)
      expect(AuditLog.where(action: "site_settings.fee_terms_activation_blocked").count).to eq(1)
    end
  end

  it "rejects legacy checkout for seven days after activation and accepts it afterward" do
    schedule
    travel_to(Time.iso8601(effective_at)) do
      ActivateFeeChangeJob.perform_now(FeeChange.sole.id)
      post "/api/v1/orders", params: { event_id: event.id, buyer_email: "legacy@example.test",
        buyer_name: "Legacy", terms_accepted: true, terms_version: PolicyRegistry.buyer_terms[:version],
        line_items: [{ ticket_type_id: ticket.id, quantity: 1 }] }
      expect(response).to have_http_status(:conflict)
      expect(response.parsed_body.fetch("error")).to include("refresh the page")
      expect(Order.where(buyer_email: "legacy@example.test")).not_to exist
    end
    travel_to(Time.iso8601(effective_at) + 8.days) do
      post "/api/v1/orders", params: { event_id: event.id, buyer_email: "legacy@example.test",
        buyer_name: "Legacy", terms_accepted: true, terms_version: PolicyRegistry.buyer_terms[:version],
        line_items: [{ ticket_type_id: ticket.id, quantity: 1 }] }
      expect(response).to have_http_status(:created)
    end
  end

  it "requires explicit approval of the future terms" do
    schedule(future_terms_approved: false)
    expect(response).to have_http_status(:unprocessable_content)
    expect(FeeChange).not_to exist
  end

  it "does not create a future approval when the current policy register is unapproved" do
    PlatformCapabilityReviews::Manager.revoke!(approval: PlatformCapabilities.active_approval("policy_register"),
      actor: admin, reason: "Approval withdrawn")
    schedule
    expect(response).to have_http_status(:unprocessable_content)
    expect(response.parsed_body.fetch("error")).to include("Approve the current policy register")
    expect(FeeChange).not_to exist
  end

  it "rejects a save when the policy digest differs from the approved preview" do
    schedule(approved_registry_digest: "0" * 64)
    expect(response).to have_http_status(:unprocessable_content)
    expect(response.parsed_body.fetch("error")).to include("preview them again")
    expect(FeeChange).not_to exist
  end

  it "reports organizations without a reachable owner and skips a removed owner's queued notice" do
    get "/api/v1/admin/settings/fee_change_preview", headers: auth_headers(admin)
    expect(response.parsed_body).to include("affected_organizer_count" => 1, "owner_email_count" => 1)
    schedule
    delivery = MessageDelivery.find_by!(template: "fee_change_notice")
    membership = profile.organization.organization_memberships.find_by!(user: profile.user)
    membership.update!(status: :revoked)
    get "/api/v1/admin/settings/fee_change_preview", headers: auth_headers(admin)
    expect(response.parsed_body).to include("affected_organizer_count" => 1, "owner_email_count" => 0,
      "unreachable_organization_ids" => [profile.organization.id])
    expect(response.parsed_body.fetch("unreachable_organizations")).to include(
      { "id" => profile.organization.id, "name" => profile.organization.name })
    MessageDeliveryJob.perform_now(delivery.id)
    expect(delivery.reload).to be_cancelled
    expect(AuditLog.where(action: "site_settings.fee_change_notice_skipped")).to exist
  end

  it "rejects a second pending change and keeps the first terms active" do
    schedule
    expect(response).to have_http_status(:ok)
    schedule(service_fee_percent: 8)
    expect(response).to have_http_status(:unprocessable_content)
    expect(FeeChange.count).to eq(1)
    expect(SiteSetting.instance.service_fee_percent).to eq(5)
  end

  it "shows the banner until the effective date and records an acknowledgment without stopping sales" do
    schedule
    notice = FeeChangeNotice.sole
    get "/api/v1/organizer/organizations", headers: auth_headers(profile.user)
    expect(response.parsed_body.sole.dig("fee_change_notice", "id")).to eq(notice.id)
    post "/api/v1/organizer/fee_change_notices/#{notice.id}/acknowledge", headers: auth_headers(profile.user)
    expect(response).to have_http_status(:ok)
    expect(notice.reload.acknowledged_at).to be_present
    expect(AuditLog.where(action: "site_settings.fee_change_acknowledged")).to exist
    get "/api/v1/organizer/organizations", headers: auth_headers(profile.user)
    expect(response.parsed_body.sole.dig("fee_change_notice", "acknowledged_at")).to be_present
    expect(event.reload.sales_open?).to be(true)
    travel_to(Time.iso8601(effective_at) + 1.second) do
      get "/api/v1/organizer/organizations", headers: auth_headers(profile.user)
      expect(response.parsed_body.sole["fee_change_notice"]).to be_nil
    end
  end
end
