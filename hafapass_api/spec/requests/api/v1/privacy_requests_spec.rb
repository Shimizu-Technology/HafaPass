require "rails_helper"

RSpec.describe "Privacy requests and holds", type: :request do
  let(:buyer) { create(:user) }
  let(:admin) { create(:user, :admin) }
  let(:order) { create(:order, user: buyer, buyer_email: buyer.email) }

  before do
    allow(EmailService).to receive(:send_guest_privacy_challenge_now)
    allow(ClerkIdentity).to receive(:verified_email_addresses).and_return([buyer.email.downcase])
  end

  it "lets an authenticated buyer submit a request and prevents another user reading the queue" do
    post "/api/v1/me/privacy_requests", params: { kind: "access" }, headers: auth_headers(buyer)
    expect(response).to have_http_status(:created)
    expect(PrivacyRequest.last.user).to eq(buyer)

    get "/api/v1/admin/privacy_requests", headers: auth_headers(buyer)
    expect(response).to have_http_status(:forbidden)
  end

  it "requires a current signed guest order link" do
    guest = create(:order)
    post "/api/v1/guest_privacy_requests", params: { kind: "deletion", order_id: guest.id,
      guest_token: "bad" }
    expect(response).to have_http_status(:forbidden)

    token = GuestOrderAccess.issue!(guest)
    post "/api/v1/guest_privacy_requests", params: { kind: "deletion", order_id: guest.id,
      guest_token: token }
    expect(response).to have_http_status(:created)
    expect(PrivacyRequest.last.order).to eq(guest)
    expect(PrivacyRequest.last.verified?).to be(false)
  end

  it "requires admin verification before execution and audits the purge setting" do
    privacy_request = PrivacyRequest.create!(kind: "access", user: buyer, requester_email: buyer.email)
    post "/api/v1/admin/privacy_requests/#{privacy_request.id}/execute", headers: auth_headers(admin)
    expect(response).to have_http_status(:conflict)

    post "/api/v1/admin/privacy_requests/#{privacy_request.id}/verify", headers: auth_headers(admin)
    expect(response).to have_http_status(:ok)
    expect(privacy_request.reload.verified_at).to be_present

    patch "/api/v1/admin/settings", params: { retention_purge_enabled: true }, headers: auth_headers(admin)
    expect(response).to have_http_status(:ok)
    expect(SiteSetting.instance.reload.retention_purge_enabled).to be(true)
    expect(AuditLog.where(action: "site_settings.retention_purge_changed", actor_user: admin)).to exist
  end


  it "requires the emailed guest challenge and rejects admin-only verification" do
    guest = create(:order)
    code = nil
    allow(EmailService).to receive(:send_guest_privacy_challenge_now) { |_item, value| code = value }
    post "/api/v1/guest_privacy_requests", params: { kind: "access", order_id: guest.id,
      guest_token: GuestOrderAccess.issue!(guest) }
    item = PrivacyRequest.last
    post "/api/v1/admin/privacy_requests/#{item.id}/verify", headers: auth_headers(admin)
    expect(response).to have_http_status(:unprocessable_entity)
    expect(item.reload.verified?).to be(false)
    post "/api/v1/guest_privacy_requests/#{item.id}/verify", params: { code: "000000" }
    expect(response).to have_http_status(:forbidden)
    post "/api/v1/guest_privacy_requests/#{item.id}/verify", params: { code: code }
    expect(response).to have_http_status(:ok)
    expect(item.reload.verified?).to be(true)
    post "/api/v1/guest_privacy_requests/#{item.id}/verify", params: { code: code }
    expect(response).to have_http_status(:forbidden)
  end

  it "requires request-specific admin confirmation to execute during dry-run" do
    item = PrivacyRequest.create!(kind: "access", user: buyer, requester_email: buyer.email,
      status: "verified", verified_at: Time.current, verified_by: admin)
    allow(DataRetention).to receive(:dry_run?).and_return(true)
    allow(EmailService).to receive(:send_privacy_request_confirmation_async)
    post "/api/v1/admin/privacy_requests/#{item.id}/execute", headers: auth_headers(admin)
    expect(response).to have_http_status(:ok)
    expect(response.parsed_body["dry_run"]).to be(true)
    expect(item.reload.executed_at).to be_nil
    expect(EmailService).not_to have_received(:send_privacy_request_confirmation_async)

    post "/api/v1/admin/privacy_requests/#{item.id}/execute", params: { confirm_dry_run: true },
      headers: auth_headers(admin)
    expect(response).to have_http_status(:ok)
    expect(item.reload.status).to eq("completed")
  end

  it "refuses administrator confirmation when the environment forces dry run" do
    item = PrivacyRequest.create!(kind: "deletion", user: buyer, requester_email: buyer.email,
      status: "verified", verified_at: Time.current, verified_by: admin)
    allow(ENV).to receive(:[]).and_call_original
    allow(ENV).to receive(:[]).with("DATA_RETENTION_DRY_RUN").and_return("true")
    allow(S3Service).to receive(:delete_upload!)
    allow(ClerkIdentity).to receive(:delete_user)
    writes = []
    callback = ->(_name, _started, _finished, _id, payload) {
      writes << payload[:sql] if payload[:sql].to_s.match?(/\A\s*(INSERT|UPDATE|DELETE|ALTER|TRUNCATE)\b/i)
    }
    ActiveSupport::Notifications.subscribed(callback, "sql.active_record") do
      post "/api/v1/admin/privacy_requests/#{item.id}/execute", params: { confirm_dry_run: true },
        headers: auth_headers(admin)
    end
    expect(response).to have_http_status(:conflict)
    expect(response.parsed_body["error"]).to include("DATA_RETENTION_DRY_RUN")
    expect(writes).to be_empty
    expect(item.reload.executed_at).to be_nil
    expect(S3Service).not_to have_received(:delete_upload!)
    expect(ClerkIdentity).not_to have_received(:delete_user)
  end

  it "throttles guest challenges per order and buyer email" do
    guest = create(:order)
    token = GuestOrderAccess.issue!(guest)
    3.times do
      post "/api/v1/guest_privacy_requests", params: { kind: "access", order_id: guest.id,
        guest_token: token }
      expect(response).to have_http_status(:created)
    end
    expect do
      post "/api/v1/guest_privacy_requests", params: { kind: "access", order_id: guest.id,
        guest_token: token }
    end.not_to change(PrivacyRequest, :count)
    expect(response).to have_http_status(:too_many_requests)
  end

  it "throttles guest challenge creation per IP across orders" do
    5.times do
      guest = create(:order)
      post "/api/v1/guest_privacy_requests", params: { kind: "access", order_id: guest.id,
        guest_token: GuestOrderAccess.issue!(guest) }
      expect(response).to have_http_status(:created)
    end
    another = create(:order)
    expect do
      post "/api/v1/guest_privacy_requests", params: { kind: "access", order_id: another.id,
        guest_token: GuestOrderAccess.issue!(another) }
    end.not_to change(PrivacyRequest, :count)
    expect(response).to have_http_status(:too_many_requests)
  end

  it "does not let a buyer place or release a hold" do
    post "/api/v1/admin/legal_holds", params: { scope_type: "order", scope_value: order.id,
      reason: "Preserve for the legal case" }, headers: auth_headers(buyer)
    expect(response).to have_http_status(:forbidden)
    expect(LegalHold.count).to eq(0)
  end
end
