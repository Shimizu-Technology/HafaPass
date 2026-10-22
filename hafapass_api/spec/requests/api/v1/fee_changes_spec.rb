# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Scheduled fee changes", type: :request do
  include ActiveSupport::Testing::TimeHelpers
  let(:admin) { create(:user, :admin) }
  let(:profile) { create(:organizer_profile, :verified) }
  let!(:event) { create(:event, :published, organizer_profile: profile, starts_at: 50.days.from_now) }
  let!(:ticket) { create(:ticket_type, event: event, price_cents: 2500, quantity_available: 20) }
  let(:effective_at) { 31.days.from_now.iso8601 }

  def schedule(attributes = {})
    patch "/api/v1/admin/settings", params: {
      service_fee_percent: 7, service_fee_flat_cents: 150, effective_at: effective_at
    }.merge(attributes), headers: auth_headers(admin)
  end

  it "previews affected organizations and enforces the configurable notice period" do
    create(:event, starts_at: 60.days.from_now) # a future draft is affected
    old = create(:event, :completed)
    get "/api/v1/admin/settings/fee_change_preview", headers: auth_headers(admin)
    expect(response.parsed_body).to include("affected_organizer_count" => 2, "minimum_notice_days" => 30)

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
    end
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
