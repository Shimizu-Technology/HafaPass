require "rails_helper"

RSpec.describe "Consent recovery and stale writes", type: :request do
  let(:user) { create(:user) }
  let(:email) { user.email.downcase }
  let(:organization) { create(:organizer_profile).organization }
  let(:url) { "/api/v1/email_preferences/#{EmailPreferences.token(email)}" }
  before do
    allow(ClerkIdentity).to receive(:email_matches?).and_return(true)
    allow(EmailService).to receive(:configured?).and_return(false)
  end

  def toggle(enabled)
    post "/api/v1/me/organizer_follows", params: { organization_id: organization.id, email_opt_in: enabled }, headers: auth_headers(user), as: :json
    expect(response).to have_http_status(:created)
  end

  %w[preferences toggle all].each do |path|
    it "R1: keeps the address association through #{path} withdrawal and signed preference restore" do
      toggle(true)
      case path
      when "toggle" then toggle(false)
      when "all" then patch url, params: { unsubscribe_all: true }, as: :json
      else patch url, params: { organizers: [{ id: organization.id, enabled: false }] }, as: :json
      end
      follow = OrganizerFollow.find_by!(user: user, organization: organization)
      expect(follow).to have_attributes(email_opted_in_address: email, email_opted_in_at: nil)
      expect(EmailPreferences.organizations(email)).to include(organization)
      expect(EmailPreferences.organizer_enabled_ids([organization.id], email)).to be_empty
      patch url, params: { organizers: [{ id: organization.id, enabled: true }] }, as: :json
      expect(response).to have_http_status(:ok)
      mailing = AudienceMailing.new(organization: organization, created_by: organization.organizer_profile.user, audience: "followers")
      expect(mailing.audience_emails).to eq([email])
      expect(EmailPreferences.organizer_enabled_ids([organization.id], email)).to eq([organization.id])
      expect(follow.reload.email_opted_in_at).to be_present
    end
  end

  %w[preferences all email_link].each do |path|
    it "R4: rejects delayed consent after a later #{path} withdrawal, then accepts an observed new choice" do
      toggle(true)
      get "/api/v1/me/organizer_follows", headers: auth_headers(user)
      observed = response.parsed_body.fetch("organizers").sole.fetch("consent_marker")
      case path
      when "all" then patch url, params: { unsubscribe_all: true }, as: :json
      when "email_link"
        post "/api/v1/marketing/unsubscribe/#{MarketingUnsubscribe.token(organization: organization, email: email)}", as: :json
      else patch url, params: { organizers: [{ id: organization.id, enabled: false }] }, as: :json
      end
      expect(response).to have_http_status(:ok)
      withdrawal = MarketingUnsubscribe.find_by!(organization: organization, email: email)
      confirmed = EmailConsent.where(email: email, action: "confirmed").count
      attributes = OrganizerFollow.find_by!(user: user, organization: organization).attributes
      payload = { organization_id: organization.id, email_opt_in: true, consent_only: true, consent_marker: observed }
      post "/api/v1/me/organizer_follows", params: payload, headers: auth_headers(user), as: :json
      expect(response).to have_http_status(:conflict)
      expect(withdrawal.reload).to be_persisted
      expect(EmailConsent.where(email: email, action: "confirmed").count).to eq(confirmed)
      expect(OrganizerFollow.find_by!(user: user, organization: organization).attributes).to eq(attributes)
      get "/api/v1/me/organizer_follows", headers: auth_headers(user)
      current = response.parsed_body.fetch("organizers").sole.fetch("consent_marker")
      expect(current).to be > observed
      post "/api/v1/me/organizer_follows", params: payload.merge(consent_marker: current), headers: auth_headers(user), as: :json
      expect(response).to have_http_status(:created)
      expect(EmailPreferences.organizer_enabled?(organization, email)).to be(true)
    end
  end
  it "F2: withdraws saved-address consent after contact changes, but rejects markers stale for either address" do
    original = email
    toggle(true)
    post "/api/v1/users/sync", params: { email: "new-contact@example.test" }, headers: auth_headers(user), as: :json
    expect(response).to have_http_status(:ok)
    expect(user.reload.email).to eq("new-contact@example.test")
    headers = auth_headers(user)
    get "/api/v1/me/organizer_follows", headers: headers
    observed = response.parsed_body.fetch("organizers").sole.fetch("consent_marker")
    payload = { organization_id: organization.id, email_opt_in: false, consent_only: true, consent_marker: observed }
    post "/api/v1/me/organizer_follows", params: payload, headers: headers, as: :json
    expect(response).to have_http_status(:created)
    follow = OrganizerFollow.find_by!(user: user, organization: organization)
    expect(follow).to have_attributes(email_opted_in_address: original, email_opted_in_at: nil)
    expect(MarketingUnsubscribe.exists?(organization: organization, email: original)).to be(true)
    expect(EmailConsent.where(email: original, scope: "organizer").order(:id).last.action).to eq("unsubscribed")
    get "/api/v1/me/organizer_follows", headers: headers
    current = response.parsed_body.fetch("organizers").sole.fetch("consent_marker")
    expect(current).to be > observed
    count = EmailConsent.count
    post "/api/v1/me/organizer_follows", params: payload, headers: headers, as: :json
    expect(response).to have_http_status(:conflict)
    expect(EmailConsent.count).to eq(count)
    # A global withdrawal for the new address also invalidates the observed choice.
    patch "/api/v1/email_preferences/#{EmailPreferences.token(user.email)}", params: { unsubscribe_all: true }, as: :json
    expect(response).to have_http_status(:ok)
    count = EmailConsent.count
    post "/api/v1/me/organizer_follows", params: payload.merge(consent_marker: current), headers: headers, as: :json
    expect(response).to have_http_status(:conflict)
    expect(EmailConsent.count).to eq(count)
    expect(follow.reload.email_opted_in_at).to be_nil
  end
end
