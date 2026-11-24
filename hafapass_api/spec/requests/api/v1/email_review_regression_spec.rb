require "rails_helper"

RSpec.describe "Email review regressions", type: :request do
  include ActiveSupport::Testing::TimeHelpers
  let(:admin) { create(:user, role: :admin) }
  let(:email) { "subscriber@example.test" }
  let(:mailing) { AudienceMailing.create!(created_by: admin, subject: "Events", body: "<script>bad</script>", audience: "platform") }
  before do
    allow(EmailService).to receive(:configured?).and_return(false)
    stub_const("ENV", ENV.to_h.merge("HAFAPASS_POSTAL_ADDRESS" => "TEST ONLY ADDRESS"))
  end

  it "lists effective organizer eligibility, including preferences withdrawal, in bulk" do
    user = create(:user)
    orgs = 3.times.map { create(:organizer_profile).organization }
    orgs.each { |org| OrganizerFollow.create!(user: user, organization: org, email_opted_in_at: Time.current, email_opted_in_address: user.email.downcase) }
    MarketingUnsubscribe.create!(email: user.email.downcase, organization: orgs.first, unsubscribed_at: Time.current)
    queries = []
    ActiveSupport::Notifications.subscribed(->(*args) { queries << args.last[:sql] }, "sql.active_record") do
      get "/api/v1/me/organizer_follows", headers: auth_headers(user)
    end
    expect(response).to have_http_status(:ok)
    expect(response.parsed_body["organizers"].to_h { |row| [row["id"], row["email_opt_in"]] })
      .to eq(orgs.to_h { |org| [org.id, org != orgs.first] })
    expect(queries.count { |sql| sql.include?('FROM "marketing_unsubscribes"') }).to eq(1)
    EmailPreference.create!(email: user.email.downcase, all_unsubscribed: true)
    get "/api/v1/me/organizer_follows", headers: auth_headers(user)
    expect(response.parsed_body["organizers"].map { |row| row["email_opt_in"] }).to eq([false, false, false])
  end

  def subscribe
    post "/api/v1/platform_subscriptions", params: { email: email, source: "footer" }, as: :json
    PlatformSubscriber.find_by!(email: email)
  end

  it "P2: rejects invalid and past schedules without changing the draft" do
    ["not-a-date", 1.day.ago.iso8601].each do |time|
      post "/api/v1/audience_mailings/#{mailing.id}/send_now", params: { scope: "platform", scheduled_at: time }, headers: auth_headers(admin), as: :json
      expect(response).to have_http_status(:unprocessable_entity)
      expect(mailing.reload.status).to eq("draft")
    end
  end

  it "P4: snapshots filters and sends exactly the displayed filtered audience" do
    subscribe.update!(status: "confirmed", interests: ["music"])
    PlatformSubscriber.create!(email: "other@example.test", source: "footer", status: "confirmed")
    payload = { scope: "platform", q: "subscriber", interest: "music", subject: "Music", body: "Shows" }
    get "/api/v1/audience_mailings/audience", params: payload, headers: auth_headers(admin)
    expect(response.parsed_body["eligible"]).to eq(1)
    post "/api/v1/audience_mailings", params: payload, headers: auth_headers(admin), as: :json
    saved = AudienceMailing.find(response.parsed_body.fetch("id"))
    expect(saved.filters).to include("q" => "subscriber", "interest" => "music")
    expect(saved.audience_emails).to eq([email])
    saved.update!(status: "scheduled", scheduled_at: Time.current)
    AudienceMailingJob.perform_now(saved.id)
    expect(saved.message_deliveries.pluck(:recipient)).to eq([email])
    expect(saved.reload.recipient_emails).to eq([])
    expect(saved.recipient_count).to eq(1)
  end

  it "P3: unfollow stops email and retains preference management" do
    org = create(:organizer_profile).organization
    user = create(:user, email: email)
    OrganizerFollow.create!(organization: org, user: user, email_opted_in_at: Time.current, email_opted_in_address: user.email.downcase)
    EmailConsent.record!(email: email, organization: org, scope: "organizer", action: "confirmed", source: "follow")
    delete "/api/v1/me/organizer_follows/#{org.id}", headers: auth_headers(user)
    expect(response).to have_http_status(:no_content)
    expect(EmailPreferences.organizer_enabled?(org, email)).to be(false)
    expect(EmailPreferences.organizations(email)).to include(org)
  end

  it "P5: fresh double opt-in after unsubscribe-all restores only platform permission" do
    subscriber = subscribe
    PlatformSubscriber.confirm!(subscriber.confirmation_token)
    patch "/api/v1/email_preferences/#{EmailPreferences.token(email)}", params: { unsubscribe_all: true }, as: :json
    travel 1.minute do
      expect { subscribe }.to change(MessageDelivery, :count).by(1)
      expect(subscriber.reload.status).to eq("pending")
      PlatformSubscriber.confirm!(subscriber.confirmation_token)
      expect(subscriber.reload.mailable?).to be(true)
    end
  end

  it "P6: encrypts preference identity, enforces purpose, and never expires visible links" do
    token = EmailPreferences.token(email)
    expect(Base64.decode64(token.split('--').first)).not_to include(email)
    travel 8.years do
      expect(EmailPreferences.email(token)).to eq(email)
      expect(EmailPreferences.email(token, scope: "platform_unsubscribe")).to be_nil
    end
  end

  it "cancels schedules and never queues cancelled or stale content" do
    mailing.update!(status: "scheduled", scheduled_at: 1.day.from_now)
    post "/api/v1/audience_mailings/#{mailing.id}/cancel", params: { scope: "platform" }, headers: auth_headers(admin), as: :json
    expect(response).to have_http_status(:ok)
    AudienceMailingJob.perform_now(mailing.id)
    expect(mailing.reload.status).to eq("cancelled")
    mailing.update!(status: "scheduled", scheduled_at: 1.day.ago)
    AudienceMailingJob.perform_now(mailing.id)
    expect(mailing.reload.status).to eq("blocked")
    expect(mailing.blocked_reason).to include("expired")
  end

  it "blocks missing addresses without automatically resuming after restoration" do
    mailing.update!(status: "scheduled", scheduled_at: Time.current)
    ENV.delete("HAFAPASS_POSTAL_ADDRESS")
    AudienceMailingJob.perform_now(mailing.id)
    expect(mailing.reload.status).to eq("blocked")
    ENV["HAFAPASS_POSTAL_ADDRESS"] = "RESTORED"
    AudienceMailingJob.perform_now(mailing.id)
    expect(mailing.message_deliveries).to be_empty
  end

  it "caps repeated confirmations per address over thirty days" do
    subscribe
    3.times do
      travel 2.hours
      subscribe
    end
    expect(MessageDelivery.where(template: "platform_confirmation").count).to eq(3)
  end

  it "records distinct consent wording versions" do
    %w[footer home checkout follow].each { |source| EmailConsent.record!(email: email, scope: "platform", source: source, action: "requested") }
    expect(EmailConsent.distinct.count(:version)).to eq(4)
  end

  it "keeps provider bounce evidence on admin suppression" do
    subscriber = subscribe
    subscriber.update!(status: "bounced")
    post "/api/v1/audience_mailings/suppress/#{subscriber.id}", params: { scope: "platform" }, headers: auth_headers(admin), as: :json
    expect(subscriber.reload.status).to eq("bounced")
    expect(EmailConsent.last.action).to eq("admin_unsubscribed")
  end

  it "bounds audience queries independent of recipient count" do
    110.times { |n| PlatformSubscriber.create!(email: "person#{n}@example.test", source: "footer", status: "confirmed") }
    queries = []
    callback = ->(*args) { queries << args.last[:sql] unless args.last[:cached] }
    ActiveSupport::Notifications.subscribed(callback, "sql.active_record") { expect(mailing.audience_emails.size).to eq(110) }
    expect(queries.grep(/SELECT/).size).to be < 15
  end

  it "resumes delivery batches without duplicates and retains no address JSON" do
    101.times { |n| PlatformSubscriber.create!(email: "person#{n}@example.test", source: "footer", status: "confirmed") }
    mailing.update!(status: "scheduled", scheduled_at: Time.current)
    3.times { AudienceMailingJob.perform_now(mailing.id) }
    expect(mailing.message_deliveries.count).to eq(101)
    expect(mailing.reload.status).to eq("queued")
    expect(mailing.recipient_emails).to be_empty
  end

  it "runs the captured transport journey from signup through unsubscribe exclusion" do
    subscriber = subscribe
    confirmation = subscriber.message_deliveries.first
    MessageDeliveryJob.perform_now(confirmation.id)
    expect(confirmation.reload.status).to eq("sent")
    post "/api/v1/platform_subscriptions/confirm/#{subscriber.confirmation_token}"
    get "/api/v1/audience_mailings/audience", params: { scope: "platform" }, headers: auth_headers(admin)
    expect(response.parsed_body["eligible"]).to eq(1)
    allow(ClerkIdentity).to receive(:email_matches?).and_return(true)
    post "/api/v1/audience_mailings/preview", params: { scope: "platform", subject: mailing.subject, body: mailing.body }, headers: auth_headers(admin), as: :json
    expect(response.parsed_body["html"]).to include("&lt;script&gt;")
    post "/api/v1/audience_mailings/#{mailing.id}/test_send", params: { scope: "platform" }, headers: auth_headers(admin), as: :json
    MessageDeliveryJob.perform_now(mailing.message_deliveries.last.id)
    post "/api/v1/audience_mailings/#{mailing.id}/send_now", params: { scope: "platform" }, headers: auth_headers(admin), as: :json
    AudienceMailingJob.perform_now(mailing.id)
    delivery = mailing.message_deliveries.find_by!(template: "audience_mailing")
    MessageDeliveryJob.perform_now(delivery.id)
    expect(delivery.reload.status).to eq("sent")
    expect(delivery.outbound_payload["html"]).to include("&lt;script&gt;")
    post "/api/v1/platform_subscriptions/unsubscribe/#{EmailPreferences.token(email, scope: 'platform_unsubscribe')}"
    expect(mailing.audience_emails).to be_empty
  end
end

RSpec.describe "Email privacy export", type: :request do
  it "includes subscribers, preferences, consent and recipient deliveries" do
    email = "privacy@example.test"
    user = create(:user, email: email)
    request = PrivacyRequest.create!(user: user, requester_email: email, kind: "access", status: "verified", verified_emails: [email])
    PlatformSubscriber.create!(email: email, source: "footer", name: "Private", interests: ["music"])
    EmailPreference.create!(email: email, all_unsubscribed: true)
    EmailConsent.record!(email: email, scope: "platform", source: "footer", action: "requested")
    export = PrivacyRequestProcessor.new(request).export
    expect(export[:platform_subscribers].first["name"]).to eq("Private")
    expect(export[:email_preferences].first["all_unsubscribed"]).to be(true)
    expect(export[:email_consents].first["email"]).to eq(email)
    expect(export).to have_key(:audience_recipients)
  end
end

RSpec.describe "Email CSV safety", type: :request do
  it "escapes every spreadsheet formula prefix including leading whitespace" do
    values = ["=formula@example.test", "+formula@example.test", "-formula@example.test", "@formula@example.test", "  =formula@example.test"]
    csv = Api::V1::AudienceMailingsController.new.send(:csv, values.map { |value| [value] })
    expect(CSV.parse(csv).flatten).to eq(values.map { |value| "'#{value}" })
  end
end

RSpec.describe "Email privacy deletion", type: :request do
  it "redacts subscription profiles and consent identities and preserves suppression" do
    email = "delete-email@example.test"
    buyer = create(:user, email: email)
    actor = create(:user, role: :admin)
    request = PrivacyRequest.create!(user: buyer, requester_email: email, kind: "deletion", status: "verified", verified_at: Time.current, verified_emails: [email])
    subscriber = PlatformSubscriber.create!(email: email, source: "footer", name: "Private name", interests: ["music"], villages: ["Dededo"])
    consent = EmailConsent.record!(email: email, scope: "platform", source: "footer", action: "requested")
    EmailPreference.create!(email: email, all_unsubscribed: false)
    allow(ENV).to receive(:[]).and_call_original
    allow(ENV).to receive(:[]).with("DATA_RETENTION_DESTRUCTIVE_ENABLED").and_return("true")
    SiteSetting.instance.update_columns(retention_purge_enabled: true)
    allow(EmailService).to receive(:configured?).and_return(false)
    allow(ClerkIdentity).to receive(:delete_user).and_return(true)
    PrivacyRequestProcessor.new(request).execute!(actor: actor)
    expect(subscriber.reload).to have_attributes(name: nil, interests: [], villages: [], status: "unsubscribed")
    expect(subscriber.email).not_to eq(email)
    expect(consent.reload.email).not_to eq(email)
    expect(EmailPreference.where(email: email)).not_to exist
    expect(PrivacyEmailSuppression.for?(email)).to be(true)
  end
end

RSpec.describe "Audience history query count", type: :request do
  it "aggregates history counts without per-recipient or per-mailing queries" do
    admin = create(:user, role: :admin)
    12.times do |n|
      mailing = AudienceMailing.create!(created_by: admin, subject: "History #{n}", body: "Fixture", audience: "platform")
      mailing.delivery("history#{n}@example.test").save!
    end
    queries = []
    ActiveSupport::Notifications.subscribed(->(*args) { queries << args.last[:sql] unless args.last[:cached] }, "sql.active_record") do
      get "/api/v1/audience_mailings", params: { scope: "platform" }, headers: auth_headers(admin)
    end
    expect(response).to have_http_status(:ok)
    expect(response.parsed_body["mailings"].size).to eq(12)
    expect(queries.grep(/SELECT/).size).to be < 20
    expect(ActiveRecord::Base.connection.indexes(:message_deliveries).map(&:name)).to include("index_message_deliveries_lower_recipient")
  end
end
