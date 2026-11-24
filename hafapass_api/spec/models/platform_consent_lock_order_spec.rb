require "rails_helper"

RSpec.describe "Platform consent lock order", type: :request do
  it "G3: locks preferences before subscribers in confirmation, subscription, withdrawal and restoration" do
    allow(EmailService).to receive(:configured?).and_return(false)
    subscriber = PlatformSubscription.call({ email: "locks@example.test", source: "footer" })
    operations = [
      -> { PlatformSubscriber.confirm!(subscriber.confirmation_token) },
      -> { EmailPreferences.unsubscribe_platform!(subscriber.email) },
      -> { PlatformSubscription.call({ email: subscriber.email, source: "footer" }) },
      -> { EmailPreferences.with_platform_locks(subscriber.email) { |pref, locked| EmailPreferences.restore_scope!(preference: pref, subscriber: locked) } }
    ]
    operations.each do |operation|
      locks = []
      callback = ->(*args) { locks << args.last[:sql] if args.last[:sql].match?(/FOR UPDATE/) }
      ActiveSupport::Notifications.subscribed(callback, "sql.active_record", &operation)
      tables = locks.filter_map { |sql| sql[/FROM "(email_preferences|platform_subscribers)"/, 1] }
      expect(tables).to eq(%w[email_preferences platform_subscribers])
    end
  end
  it "R2: takes preference, subscriber and follow locks before withdrawal and consent writes on DELETE" do
    user = create(:user)
    organization = create(:organizer_profile).organization
    PlatformSubscriber.create!(email: user.email, source: "footer")
    EmailPreference.create!(email: user.email)
    OrganizerFollow.create!(user: user, organization: organization, email_opted_in_address: user.email, email_opted_in_at: Time.current)
    statements = []
    callback = ->(*args) { statements << args.last[:sql] }
    ActiveSupport::Notifications.subscribed(callback, "sql.active_record") do
      delete "/api/v1/me/organizer_follows/#{organization.id}", headers: auth_headers(user)
    end
    expect(response).to have_http_status(:no_content)
    positions = %w[email_preferences platform_subscribers organizer_follows].map do |table|
      statements.index { |sql| sql.include?(%(FROM "#{table}")) && sql.include?("FOR UPDATE") }
    end
    positions << statements.index { |sql| sql.include?('INSERT INTO "marketing_unsubscribes"') }
    positions << statements.index { |sql| sql.include?('INSERT INTO "email_consents"') }
    expect(positions).not_to include(nil)
    expect(positions).to eq(positions.sort)
  end
end
