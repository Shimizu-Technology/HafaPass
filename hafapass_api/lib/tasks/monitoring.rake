# frozen_string_literal: true

namespace :hafapass do
  namespace :monitoring do
    # Same cooldown and failure behavior as the admin button. The one
    # difference: a shell has no signed-in user, so it writes a log line
    # (monitoring_test_alert) instead of an audit_logs row.
    desc "Send one labelled [TEST] event to Sentry: bin/rails hafapass:monitoring:test_alert[stripe_webhooks_silent]"
    task :test_alert, [:kind] => :environment do |_task, args|
      kind = args[:kind].to_s
      abort "Choose one of: #{MonitoringTestAlert::KINDS.join(', ')}" unless MonitoringTestAlert::KINDS.include?(kind)
      abort "SENTRY_DSN is not set, so the test would go nowhere." if ENV["SENTRY_DSN"].blank?
      abort "A test alert was sent in the last #{MonitoringTestAlert::COOLDOWN.to_i} seconds; wait and retry." unless MonitoringTestAlert.claim_slot!

      event_id = MonitoringTestAlert.send!(kind: kind)
      if event_id.blank?
        MonitoringTestAlert.release_slot!
        abort "Sentry did not accept the test alert, so nothing was sent. Check SENTRY_DSN and SENTRY_ENABLED_ENVIRONMENTS."
      end
      Sentry.flush if Sentry.respond_to?(:flush)
      puts "Queued test alert #{kind} for Sentry (event #{event_id})"
    end

    desc "Print the Stripe webhook health snapshot as JSON"
    task webhook_health: :environment do
      puts JSON.pretty_generate(Operations::StripeWebhookHealth.call)
    end
  end
end
