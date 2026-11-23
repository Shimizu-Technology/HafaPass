# frozen_string_literal: true

namespace :hafapass do
  desc "Report readiness and yesterday's aggregate live Stripe sales in Guam time"
  task daily_summary: :environment do
    guam = Time.find_zone!("Pacific/Guam")
    day = guam.today - 1
    window = guam.local(day.year, day.month, day.day)...guam.today.in_time_zone(guam)
    readiness = SystemReadiness.call.fetch(:status)

    summary = ActiveRecord::Base.transaction do
      ActiveRecord::Base.connection.execute("SET TRANSACTION READ ONLY")
      captures = Payment.live_or_legacy_capture.where(
        provider: "stripe", provider_environment: "live", currency: "usd", succeeded_at: window
      ).joins(order: :event).where(events: { live_money_proof_candidate: false })

      {
        guam_date: day.iso8601,
        revision: ApplicationRevision.configured? ? ApplicationRevision.current.downcase : nil,
        readiness: readiness,
        live_stripe_captured_orders: captures.distinct.count(:order_id),
        live_stripe_gross_captured_usd_cents: captures.sum(:amount_cents),
        stripe_webhook_receipts_currently_failed: WebhookEvent.failed.where(provider: "stripe").count
      }
    end

    puts JSON.generate(summary)
  end
end
