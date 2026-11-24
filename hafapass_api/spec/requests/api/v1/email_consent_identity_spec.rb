require "rails_helper"

RSpec.describe "Address-bound email consent", type: :request do
  include ActiveSupport::Testing::TimeHelpers
  let(:user) { create(:user) }
  let(:email) { user.email.downcase }
  let(:organization) { create(:organizer_profile).organization }
  before do
    allow(ClerkIdentity).to receive(:email_matches?).and_return(true)
    allow(EmailService).to receive(:configured?).and_return(false)
  end

  def follow(org = organization)
    post "/api/v1/me/organizer_follows", params: { organization_id: org.id, email_opt_in: true }, headers: auth_headers(user), as: :json
    expect(response).to have_http_status(:created)
  end

  def preferences(choices)
    patch "/api/v1/email_preferences/#{EmailPreferences.token(email)}", params: choices, as: :json
    expect(response).to have_http_status(:ok)
  end

  def mailing(org = organization)
    AudienceMailing.new(organization: org, created_by: org.organizer_profile.user, audience: "followers", subject: "Events", body: "News")
  end

  it "G1: pins verified follower consent after users/sync changes the contact address" do
    original = email
    follow
    post "/api/v1/users/sync", params: { email: "unverified@example.test" }, headers: auth_headers(user), as: :json
    expect(response).to have_http_status(:ok)
    expect(user.reload.email).to eq("unverified@example.test")
    expect(mailing.audience_emails).to eq([original])
    expect(mailing.eligible?(user.email)).to be(false)
    expect(EmailPreferences.organizer_enabled_ids([organization.id], user.email)).to be_empty
    expect(EmailPreferences.organizations(user.email)).not_to include(organization)
    expect(EmailPreferences.organizations(original)).to include(organization)
    create(:order, :completed, event: create(:event, organizer_profile: organization.organizer_profile), buyer_email: user.email, marketing_opt_in: false)
    expect(mailing.tap { |draft| draft.audience = "buyers" }.audience_emails).to be_empty
    patch "/api/v1/email_preferences/#{EmailPreferences.token(original)}", params: { organizers: [{ id: organization.id, enabled: true }] }, as: :json
    expect(response).to have_http_status(:ok)
    expect(OrganizerFollow.find_by!(user: user, organization: organization).email_opted_in_address).to eq(original)
    patch "/api/v1/email_preferences/#{EmailPreferences.token(original)}", params: { organizers: [{ id: organization.id, enabled: false }] }, as: :json
    expect(response).to have_http_status(:ok)
    expect(OrganizerFollow.find_by!(user: user, organization: organization).email_opted_in_at).to be_nil
    expect(mailing.eligible?(original)).to be(false)
  end

  it "G1: fails closed for legacy follows without an address snapshot" do
    OrganizerFollow.create!(user: user, organization: organization, email_opted_in_at: Time.current)
    expect(mailing.audience_emails).to be_empty
    expect(mailing.eligible?(email)).to be(false)
  end

  %w[follow preferences].each do |path|
    it "G4: restores only organizer A after unsubscribe-all through #{path}" do
      other = create(:organizer_profile).organization
      follow
      follow(other)
      PlatformSubscriber.create!(email: email, source: "footer", status: "confirmed")
      preferences(unsubscribe_all: true)
      path == "follow" ? follow : preferences(organizers: [{ id: organization.id, enabled: true }])
      expect(mailing.eligible?(email)).to be(true)
      expect(mailing(other).eligible?(email)).to be(false)
      expect(PlatformSubscriber.find_by!(email: email).mailable?).to be(false)
      expect(MarketingUnsubscribe.exists?(organization: other, email: email)).to be(true)
      expect(EmailPreference.blocked?(email)).to be(false)
    end
  end

  %w[true false].each do |double_opt_in|
    it "G5: restores platform only with EMAIL_DOUBLE_OPT_IN=#{double_opt_in}" do
      stub_const("ENV", ENV.to_h.merge("EMAIL_DOUBLE_OPT_IN" => double_opt_in))
      follow
      PlatformSubscriber.create!(email: email, source: "footer", status: "confirmed")
      EmailPreference.find_by!(email: email).update!(all_unsubscribed: true)
      EmailPreferences.unsubscribe_platform!(email)
      travel 1.minute do
        subscriber = PlatformSubscription.call({ email: email, source: "footer" })
        if double_opt_in == "true"
          expect(subscriber.status).to eq("pending")
          expect(EmailPreference.blocked?(email)).to be(true)
          PlatformSubscriber.confirm!(subscriber.confirmation_token)
        end
        expect(subscriber.reload.mailable?).to be(true)
      end
      expect(mailing.eligible?(email)).to be(false)
      expect(MarketingUnsubscribe.exists?(organization: organization, email: email)).to be(true)
    end
  end

  it "C6: rejects a stale consent-only POST after DELETE without recreating or confirming" do
    follow
    delete "/api/v1/me/organizer_follows/#{organization.id}", headers: auth_headers(user)
    expect(response).to have_http_status(:no_content)
    confirmed = EmailConsent.where(email: email, organization: organization, action: "confirmed").count
    expect do
      post "/api/v1/me/organizer_follows", params: { organization_id: organization.id, email_opt_in: true, consent_only: true }, headers: auth_headers(user), as: :json
    end.not_to change(OrganizerFollow, :count)
    expect(response).to have_http_status(:not_found)
    expect(OrganizerFollow.exists?(user: user, organization: organization)).to be(false)
    expect(MarketingUnsubscribe.exists?(organization: organization, email: email)).to be(true)
    expect(EmailConsent.where(email: email, organization: organization, action: "confirmed").count).to eq(confirmed)
  end

  it "C6: updates existing follow consent without creating a relationship" do
    follow
    post "/api/v1/me/organizer_follows", params: { organization_id: organization.id, email_opt_in: false, consent_only: true, consent_marker: EmailPreferences.consent_markers([organization.id], email).fetch(organization.id) }, headers: auth_headers(user), as: :json
    expect(response).to have_http_status(:created)
    expect(OrganizerFollow.find_by!(user: user, organization: organization).email_opted_in_at).to be_nil
    expect(mailing.eligible?(email)).to be(false)
  end
end
