require "rails_helper"

RSpec.describe "Platform consent lock order" do
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
end
