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
      callback = ->(*args) { locks << args.last[:sql] if args.last[:sql].match?(/FOR UPDATE|pg_advisory_xact_lock/) }
      ActiveSupport::Notifications.subscribed(callback, "sql.active_record", &operation)
      expect(locks.first).to include("pg_advisory_xact_lock")
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
  it "F1: nests sorted email preference/subscriber locks and locks follows before deletion's first organization lock" do
    allow(ENV).to receive(:[]).and_call_original
    allow(ENV).to receive(:[]).with("DATA_RETENTION_DESTRUCTIVE_ENABLED").and_return("true")
    SiteSetting.instance.update_columns(retention_purge_enabled: true)
    allow(ClerkIdentity).to receive(:delete_user).and_return(true)
    allow(EmailService).to receive(:send_privacy_request_confirmation_async).and_return(build_stubbed(:message_delivery, id: 1))
    allow(MessageDeliveryJob).to receive(:perform_now)
    admin = create(:user, :admin)
    user = create(:user, email: "z-owner@example.test")
    order = create(:order, user: user, buyer_email: user.email)
    addresses = [user.email, "a-verified@example.test", "m-saved@example.test"]
    pairs = addresses.sort.flat_map do |email|
      preference = EmailPreference.create!(email: email)
      subscriber = PlatformSubscriber.create!(email: email, source: "footer")
      [["email_preferences", preference.id], ["platform_subscribers", subscriber.id]]
    end
    OrganizerFollow.create!(user: user, organization: order.event.organization,
      email_opted_in_address: "m-saved@example.test", email_opted_in_at: Time.current)
    request = PrivacyRequest.create!(kind: "deletion", user: user, requester_email: user.email,
      verified_emails: ["a-verified@example.test", user.email, user.email.upcase],
      status: "verified", verified_at: Time.current, verified_by: admin)
    locks = []
    callback = lambda do |*args|
      payload = args.last
      next unless payload[:sql].include?("FOR UPDATE")
      table = payload[:sql][/FROM "(email_preferences|platform_subscribers|organizer_follows|organizations)"/, 1]
      next unless table
      id = payload[:binds].find { |bind| bind.name == "id" }&.value_for_database
      locks << [table, id]
    end
    ActiveSupport::Notifications.subscribed(callback, "sql.active_record") do
      PrivacyRequestProcessor.new(request).execute!(actor: admin)
    end
    expect(locks.first(pairs.size)).to eq(pairs)
    organization_lock = locks.index { |table, _id| table == "organizations" }
    follow_lock = locks.index { |table, _id| table == "organizer_follows" }
    expect(organization_lock).to be_present
    expect(follow_lock).to be >= pairs.size
    expect(follow_lock).to be < organization_lock
    expect(request.reload.status).to eq("completed")
  end
  it "A1: takes the address advisory lock before lookups even when lock-only mode has no rows" do
    email = "  NO-ROWS@example.test  "
    statements = []
    callback = ->(*args) { statements << args.last[:sql] unless args.last[:sql].match?(/BEGIN|SAVEPOINT/) }
    before = [EmailPreference.count, PlatformSubscriber.count]
    ActiveSupport::Notifications.subscribed(callback, "sql.active_record") do
      EmailPreferences.with_platform_locks(email, create_preference: false) do |preference, subscriber|
        expect(preference).to be_nil
        expect(subscriber).to be_nil
      end
    end
    expect(statements.first).to include("pg_advisory_xact_lock")
    expect(statements.none? { |sql| sql.include?("INSERT INTO") }).to be(true)
    expect([EmailPreference.count, PlatformSubscriber.count]).to eq(before)
  end

  it "A1: excludes another connection for the same normalized address without creating rows" do
    email = "  EMPTY@example.test  "
    main_pid = ApplicationRecord.connection.select_value("SELECT pg_backend_pid()")
    EmailPreferences.with_platform_locks(email, create_preference: false) do
      config = ApplicationRecord.connection_db_config.configuration_hash
      other = PG.connect(host: config[:host], port: config[:port], dbname: config[:database],
        user: config[:username], password: config[:password])
      begin
        other.exec("BEGIN")
        pid = other.exec("SELECT pg_backend_pid()").getvalue(0, 0).to_i
        acquired = other.exec_params("SELECT pg_try_advisory_xact_lock($1, hashtext($2))",
          [EmailPreferences::ADVISORY_NAMESPACE, email.strip.downcase]).getvalue(0, 0)
        expect(pid).not_to eq(main_pid)
        expect(acquired).to eq("f")
      ensure
        other.exec("ROLLBACK")
        other.close
      end
    end
    expect(EmailPreference.where(email: email.strip.downcase)).not_to exist
    expect(PlatformSubscriber.where(email: email.strip.downcase)).not_to exist
  end
  it "A1: locks the address before the first organization lock in waitlist organizer withdrawal" do
    entry = create(:waitlist_entry)
    locks = []
    callback = ->(*args) { locks << args.last if args.last[:sql].match?(/FOR UPDATE|pg_advisory_xact_lock/) }
    ActiveSupport::Notifications.subscribed(callback, "sql.active_record") do
      WaitlistUnsubscribe.stop!(entry, all: true)
    end
    expect(locks.first[:name]).to eq("Email consent lock")
    expect(locks.index { |payload| payload[:sql].include?('FROM "organizations"') }).to be > 0
    expect(entry.reload.status).to eq("cancelled")
    expect(MarketingUnsubscribe.exists?(organization: entry.event.organization, email: entry.email)).to be(true)
    expect(EmailPreference.where(email: entry.email)).not_to exist
  end
end
