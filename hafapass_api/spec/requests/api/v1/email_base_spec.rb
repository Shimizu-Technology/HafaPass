require "rails_helper"

RSpec.describe "Email base", type: :request do
  include ActiveSupport::Testing::TimeHelpers
  let(:admin) { create(:user, role: :admin) }
  let(:email) { "alerts@example.test" }

  before { allow(EmailService).to receive(:configured?).and_return(false) }

  def subscribe
    post "/api/v1/platform_subscriptions", params: { email: email, source: "footer" }, as: :json
    PlatformSubscriber.find_by!(email: email)
  end

  it "captures consent without enumeration and confirms only a current, unexpired token" do
    subscriber = subscribe
    expect(response).to have_http_status(:accepted)
    expect(subscriber.status).to eq("pending")
    expect(subscriber.mailable?).to be(false)
    expect(EmailConsent.last).to have_attributes(version: "event-alerts-footer-v1", source: "footer", action: "requested")
    expect { subscribe }.not_to change(MessageDelivery, :count)
    token = subscriber.confirmation_token
    post "/api/v1/platform_subscriptions/confirm/#{token}"
    expect(response).to have_http_status(:ok)
    expect(subscriber.reload.mailable?).to be(true)
    EmailPreferences.unsubscribe_platform!(email)
    post "/api/v1/platform_subscriptions/confirm/#{token}"
    expect(response).to have_http_status(:unprocessable_entity)
    expect(subscriber.reload.status).to eq("unsubscribed")
  end

  it "rejects expired and forged confirmations and invalid input without enumeration" do
    subscriber = subscribe
    token = subscriber.confirmation_token
    travel 3.days do
      post "/api/v1/platform_subscriptions/confirm/#{token}"
      expect(response).to have_http_status(:unprocessable_entity)
    end
    post "/api/v1/platform_subscriptions/confirm/forged"
    expect(response).to have_http_status(:unprocessable_entity)
    post "/api/v1/platform_subscriptions", params: { email: "bad" }, as: :json
    expect(response.parsed_body).to eq("accepted" => true)
  end

  it "supports the explicit double opt-in configuration" do
    stub_const("ENV", ENV.to_h.merge("EMAIL_DOUBLE_OPT_IN" => "false"))
    expect(subscribe.status).to eq("confirmed")
    expect(MessageDelivery.where(template: "platform_confirmation")).to be_empty
  end

  it "scopes preferences tokens and leaves transactional classification unchanged" do
    subscribe.update!(status: "confirmed")
    token = EmailPreferences.token(email)
    patch "/api/v1/email_preferences/#{token}", params: { unsubscribe_all: true }, as: :json
    expect(response).to have_http_status(:ok)
    expect(EmailPreference.blocked?(email)).to be(true)
    expect(PlatformSubscriber.find_by!(email: email).mailable?).to be(false)
    expect(MessageDelivery.new(channel: "email", template: "order_confirmation", recipient: email).marketing_unsubscribed?).to be(false)
    patch "/api/v1/email_preferences/#{EmailPreferences.token(email, scope: 'platform_unsubscribe')}", params: { platform: true }, as: :json
    expect(response).to have_http_status(:unprocessable_entity)
    patch "/api/v1/email_preferences/#{token}", params: { platform: true }, as: :json
    expect(response.parsed_body["platform"]).to be(true), response.body
  end

  it "retains RFC 8058 platform-only scope" do
    subscribe.update!(status: "confirmed")
    token = EmailPreferences.token(email, scope: "platform_unsubscribe")
    post "/api/v1/platform_subscriptions/unsubscribe/#{token}", params: { "List-Unsubscribe" => "One-Click" }
    expect(response).to have_http_status(:ok)
    expect(PlatformSubscriber.find_by!(email: email).status).to eq("unsubscribed")
    expect(EmailPreference.blocked?(email)).to be(false)
  end

  it "requires platform admin authority and logs formula-safe filtered exports" do
    subscribe.update!(status: "confirmed")
    get "/api/v1/audience_mailings/audience", params: { scope: "platform" }, headers: auth_headers(create(:user))
    expect(response).to have_http_status(:forbidden)
    get "/api/v1/audience_mailings/audience", params: { scope: "platform", status: "confirmed", format: "csv" }, headers: auth_headers(admin)
    expect(response).to have_http_status(:ok)
    expect(response.body).to include(email)
    expect(AuditLog.where(action: "email.audience_exported")).to exist
    post "/api/v1/audience_mailings/suppress/#{PlatformSubscriber.first.id}", params: { scope: "platform" }, headers: auth_headers(admin)
    expect(response).to have_http_status(:no_content)
    expect(PlatformSubscriber.first.status).to eq("unsubscribed")
  end

  it "previews exact escaped HTML, requires an address, and isolates verified self-tests" do
    headers = auth_headers(admin)
    payload = { scope: "platform", subject: "Upcoming events", body: "<script>alert(1)</script>" }
    post "/api/v1/audience_mailings/preview", params: payload, headers: headers, as: :json
    expect(response).to have_http_status(:unprocessable_entity)
    stub_const("ENV", ENV.to_h.merge("HAFAPASS_POSTAL_ADDRESS" => "TEST FIXTURE ADDRESS — not for delivery"))
    post "/api/v1/audience_mailings/preview", params: payload, headers: headers, as: :json
    expect(response).to have_http_status(:ok)
    expect(response.parsed_body["html"]).to include("&lt;script&gt;", "Email preferences", "Unsubscribe")
    post "/api/v1/audience_mailings", params: payload, headers: headers, as: :json
    id = response.parsed_body.fetch("id")
    allow(ClerkIdentity).to receive(:email_matches?).and_return(false)
    post "/api/v1/audience_mailings/#{id}/test_send", params: { scope: "platform", email: email }, headers: headers, as: :json
    expect(response).to have_http_status(:forbidden)
    allow(ClerkIdentity).to receive(:email_matches?).and_return(true)
    post "/api/v1/audience_mailings/#{id}/test_send", params: { scope: "platform", email: email }, headers: headers, as: :json
    expect(response).to have_http_status(:ok)
    delivery = MessageDelivery.last
    expect(delivery).to have_attributes(recipient: admin.email, template: "audience_test")
    expect(delivery.metadata["subject"]).to start_with("[TEST]")
    get "/api/v1/audience_mailings", params: { scope: "platform" }, headers: headers
    expect(response.parsed_body["mailings"].first["counts"]).to eq({})
  end

  it "keeps organizer follower consent explicit and prevents cross-organizer reads" do
    profile = create(:organizer_profile)
    other = create(:organizer_profile)
    user = create(:user)
    post "/api/v1/me/organizer_follows", params: { organization_id: profile.organization.id }, headers: auth_headers(user), as: :json
    expect(OrganizerFollow.last.email_opted_in_at).to be_nil
    allow(ClerkIdentity).to receive(:email_matches?).and_return(true)
    post "/api/v1/me/organizer_follows", params: { organization_id: profile.organization.id, email_opt_in: true }, headers: auth_headers(user), as: :json
    expect(OrganizerFollow.last.email_opted_in_at).to be_present
    get "/api/v1/audience_mailings/audience", params: { audience: "followers" }, headers: auth_headers(profile.user).merge("X-Organization-Id" => profile.organization.id.to_s)
    expect(response.parsed_body["eligible"]).to eq(1)
    get "/api/v1/audience_mailings/audience", params: { audience: "followers" }, headers: auth_headers(other.user).merge("X-Organization-Id" => other.organization.id.to_s)
    expect(response.parsed_body["eligible"]).to eq(0)
  end
  it "does not reactivate other organizers after a global opt-out" do
    first = create(:organizer_profile).organization
    second = create(:organizer_profile).organization
    user = create(:user, email: email)
    [first, second].each { |org| OrganizerFollow.create!(user: user, organization: org, email_opted_in_at: Time.current, email_opted_in_address: user.email.downcase, email_consent_version: EmailConsent::VERSION) }
    token = EmailPreferences.token(email)
    patch "/api/v1/email_preferences/#{token}", params: { unsubscribe_all: true }, as: :json
    patch "/api/v1/email_preferences/#{token}", params: { organizers: [{ id: first.id, enabled: true }] }, as: :json
    expect(response).to have_http_status(:ok)
    expect(EmailPreferences.organizer_enabled?(first, email)).to be(true)
    expect(EmailPreferences.organizer_enabled?(second, email)).to be(false)
  end

  it "denies organizer campaigns and exports without marketing authority" do
    org = create(:organizer_profile).organization
    member = create(:user)
    create(:organization_membership, user: member, organization: org, role: :finance)
    get "/api/v1/audience_mailings/audience", params: { audience: "followers", format: "csv" }, headers: auth_headers(member).merge("X-Organization-Id" => org.id.to_s)
    expect(response).to have_http_status(:forbidden)
    post "/api/v1/audience_mailings", params: { subject: "Events", body: "Body", audience: "buyers" }, headers: auth_headers(member).merge("X-Organization-Id" => org.id.to_s), as: :json
    expect(response).to have_http_status(:forbidden)
  end

  it "schedules once and rejects another scope's mailing id" do
    stub_const("ENV", ENV.to_h.merge("HAFAPASS_POSTAL_ADDRESS" => "TEST FIXTURE ADDRESS"))
    mailing = AudienceMailing.create!(created_by: admin, subject: "Events", body: "Body", audience: "platform")
    post "/api/v1/audience_mailings/#{mailing.id}/send_now", params: { scope: "platform", scheduled_at: 1.day.from_now.iso8601 }, headers: auth_headers(admin), as: :json
    expect(response).to have_http_status(:ok)
    expect(mailing.reload.status).to eq("scheduled")
    post "/api/v1/audience_mailings/#{mailing.id}/send_now", params: { scope: "platform" }, headers: auth_headers(admin), as: :json
    expect(response).to have_http_status(:conflict)
    profile = create(:organizer_profile)
    post "/api/v1/audience_mailings/#{mailing.id}/send_now", headers: auth_headers(profile.user).merge("X-Organization-Id" => profile.organization.id.to_s), as: :json
    expect(response).to have_http_status(:not_found)
  end
  it "C3: returns 409 without suppression writes if erasure rewrote the subscriber before locking" do
    subscriber = PlatformSubscriber.create!(email: email, source: "footer", status: "confirmed")
    allow(EmailPreferences).to receive(:with_platform_locks).and_wrap_original do |method, address, **options, &block|
      subscriber.update!(email: "deleted+subscriber@example.test")
      method.call(address, **options, &block)
    end
    expect do
      post "/api/v1/audience_mailings/suppress/#{subscriber.id}", params: { scope: "platform" }, headers: auth_headers(admin)
    end.not_to change(EmailConsent, :count)
    expect(response).to have_http_status(:conflict)
    expect(response.parsed_body["error"]).to eq("Subscriber changed; reload")
    expect(subscriber.reload.status).to eq("confirmed")
    expect(AuditLog.where(action: "email.subscriber_suppressed")).not_to exist
    expect(EmailPreference.where(email: email)).not_to exist
  end
end
