# frozen_string_literal: true

namespace :hafapass do
  namespace :monitoring do
    desc "Send one labelled [TEST] event to Sentry: bin/rails hafapass:monitoring:test_alert[stripe_webhooks_silent]"
    task :test_alert, [:kind] => :environment do |_task, args|
      kind = args[:kind].to_s
      abort "Choose one of: #{MonitoringTestAlert::KINDS.join(', ')}" unless MonitoringTestAlert::KINDS.include?(kind)
      abort "SENTRY_DSN is not set, so the test would go nowhere." if ENV["SENTRY_DSN"].blank?

      event_id = MonitoringTestAlert.send!(kind: kind)
      Sentry.flush if Sentry.respond_to?(:flush)
      puts "Sent test alert #{kind} (Sentry event #{event_id.presence || 'not sent: check SENTRY_ENABLED_ENVIRONMENTS'})"
    end

    desc "Print the Stripe webhook health snapshot as JSON"
    task webhook_health: :environment do
      puts JSON.pretty_generate(Operations::StripeWebhookHealth.call)
    end
  end
end
