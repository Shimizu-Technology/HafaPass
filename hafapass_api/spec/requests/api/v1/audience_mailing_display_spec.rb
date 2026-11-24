require "rails_helper"

# Display-only fields added for the email screens (#19). They describe the
# filtered list so the UI can explain who is left out; recipient selection is
# unchanged and still comes only from AudienceMailing#audience_emails.
RSpec.describe "Audience mailing display fields", type: :request do
  let(:admin) { create(:user, role: :admin) }

  before { allow(EmailService).to receive(:configured?).and_return(false) }

  def subscriber(email, status, source: "footer")
    PlatformSubscriber.create!(email: email, status: status, source: source)
  end

  it "explains the platform list: considered, filtered status breakdown, and unchanged eligibility" do
    subscriber("one@example.test", "confirmed")
    subscriber("two@example.test", "confirmed")
    subscriber("blocked@example.test", "confirmed")
    subscriber("waiting@example.test", "pending")
    subscriber("gone@example.test", "unsubscribed")
    subscriber("other-source@example.test", "bounced", source: "checkout")
    EmailPreference.create!(email: "blocked@example.test", all_unsubscribed: true)

    get "/api/v1/audience_mailings/audience", params: { scope: "platform", source: "footer" }, headers: auth_headers(admin)

    expect(response).to have_http_status(:ok)
    body = response.parsed_body
    expect(body["eligible"]).to eq(2)
    expect(body["considered"]).to eq(5)
    expect(body["count"]).to eq(5)
    expect(body["status_breakdown"]).to eq("confirmed" => 3, "pending" => 1, "unsubscribed" => 1)
    expect(body["counts"]).to include("bounced" => 1)
    expect(AudienceMailing.new(created_by: admin, subject: "S", body: "B", audience: "platform", filters: { "source" => "footer" }).audience_emails)
      .to contain_exactly("one@example.test", "two@example.test")
  end

  it "reports organizer candidates separately from eligible recipients" do
    profile = create(:organizer_profile)
    org = profile.organization
    opted = create(:user)
    unsubscribed = create(:user)
    OrganizerFollow.create!(user: opted, organization: org, email_opted_in_at: Time.current, email_opted_in_address: opted.email.downcase, email_consent_version: EmailConsent::VERSION)
    OrganizerFollow.create!(user: unsubscribed, organization: org, email_opted_in_at: Time.current, email_opted_in_address: unsubscribed.email.downcase, email_consent_version: EmailConsent::VERSION)
    MarketingUnsubscribe.create!(organization: org, email: unsubscribed.email.downcase, unsubscribed_at: Time.current)
    headers = auth_headers(profile.user).merge("X-Organization-Id" => org.id.to_s)

    get "/api/v1/audience_mailings/audience", params: { audience: "followers" }, headers: headers

    expect(response.parsed_body).to include("eligible" => 1, "count" => 1, "considered" => 2)

    get "/api/v1/audience_mailings/audience", params: { audience: "followers", q: opted.email.upcase }, headers: headers
    expect(response.parsed_body).to include("eligible" => 1, "considered" => 1)
  end

  describe "audience scope (organizers never see platform list counts)" do
    let(:profile) { create(:organizer_profile) }
    let(:org) { profile.organization }
    let(:headers) { auth_headers(profile.user).merge("X-Organization-Id" => org.id.to_s) }

    before do
      subscriber("on-platform@example.test", "confirmed")
      subscriber("also-platform@example.test", "confirmed")
    end

    it "rejects the platform audience and unknown audiences for organizers before counting anyone" do
      [{ audience: "platform" }, { audience: "platform", q: "on-platform@example.test" }, { audience: "everyone" }].each do |params|
        get "/api/v1/audience_mailings/audience", params: params, headers: headers

        expect(response).to have_http_status(:unprocessable_entity)
        expect(response.parsed_body.keys).to eq(["error"])
      end
    end

    it "does not export the platform audience to organizers" do
      expect {
        get "/api/v1/audience_mailings/audience", params: { audience: "platform", format: "csv" }, headers: headers
      }.not_to change(AuditLog, :count)

      expect(response).to have_http_status(:unprocessable_entity)
      expect(response.body).not_to include("on-platform@example.test")
    end

    it "counts only the organizer's own list when searching for a platform-only address" do
      get "/api/v1/audience_mailings/audience", params: { audience: "buyers", q: "on-platform@example.test" }, headers: headers

      expect(response).to have_http_status(:ok)
      expect(response.parsed_body).to include("eligible" => 0, "count" => 0, "considered" => 0, "subscribers" => [])
    end

    it "never counts platform subscribers for an organizer mailing, even if built directly" do
      mailing = AudienceMailing.new(organization: org, created_by: profile.user, subject: "S", body: "B", audience: "platform")

      expect(mailing.candidate_count).to eq(0)
    end

    it "still lets an admin search the platform list" do
      get "/api/v1/audience_mailings/audience", params: { scope: "platform", q: "on-platform" }, headers: auth_headers(admin)

      expect(response.parsed_body).to include("eligible" => 1, "considered" => 1)
    end
  end

  it "returns the address a self-test went to" do
    stub_const("ENV", ENV.to_h.merge("HAFAPASS_POSTAL_ADDRESS" => "TEST FIXTURE ADDRESS — not for delivery"))
    allow(ClerkIdentity).to receive(:email_matches?).and_return(true)
    mailing = AudienceMailing.create!(created_by: admin, subject: "Events", body: "Body", audience: "platform")

    post "/api/v1/audience_mailings/#{mailing.id}/test_send", params: { scope: "platform" }, headers: auth_headers(admin), as: :json

    expect(response.parsed_body).to eq("queued" => true, "recipient" => admin.email)
    expect(MessageDelivery.last).to have_attributes(recipient: admin.email, template: "audience_test")
  end
end
