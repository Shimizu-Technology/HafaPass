# frozen_string_literal: true

# Platform-admin view of the monitoring that reaches Leon's phone: Stripe
# webhook health, the latest summary, and a clearly labelled test alert for
# checking Sentry rules (docs/MONITORING_SETUP.md).
class Api::V1::Admin::MonitoringController < Api::V1::Admin::BaseController
  TEST_ALERT_KINDS = MonitoringTestAlert::KINDS

  # GET /api/v1/admin/monitoring
  def show
    response.headers["Cache-Control"] = "no-store"
    render json: {
      stripe_webhooks: Operations::StripeWebhookHealth.call,
      summary: Operations::DailySummary.call(date: params[:date]),
      sentry: { configured: ENV["SENTRY_DSN"].present?, sending_enabled: sentry_sending?,
                environment: ENV.fetch("SENTRY_ENVIRONMENT", Rails.env) },
      test_alert_kinds: TEST_ALERT_KINDS
    }
  rescue ArgumentError => e
    render json: { error: e.message }, status: :unprocessable_entity
  end

  # POST /api/v1/admin/monitoring/test_alert { kind: "stripe_webhooks_silent" }
  # Sends one Sentry event shaped like the real alert for `kind` (same tag),
  # plus monitoring_test=true and a "[TEST]" title, under its own fingerprint,
  # so it never touches the real issue or the app's alert state.
  def test_alert
    kind = params[:kind].to_s
    unless TEST_ALERT_KINDS.include?(kind)
      return render json: { error: "Unknown alert kind", kinds: TEST_ALERT_KINDS }, status: :unprocessable_entity
    end
    unless ENV["SENTRY_DSN"].present?
      return render json: { error: "Sentry is not configured (SENTRY_DSN), so a test alert would go nowhere." },
        status: :unprocessable_entity
    end
    return too_soon unless MonitoringTestAlert.claim_slot!

    event_id = MonitoringTestAlert.send!(kind: kind, actor: @current_user)
    if event_id.blank?
      MonitoringTestAlert.release_slot!
      return render json: { sent: false, error: "Sentry did not accept the test alert, so nothing was sent. " \
        "Check that SENTRY_DSN is set and this environment is listed in SENTRY_ENABLED_ENVIRONMENTS." },
        status: :bad_gateway
    end

    AuditLogger.record!(action: "monitoring.test_alert_sent", auditable: @current_user, actor: @current_user,
      metadata: { kind: kind, sentry_event_id: event_id })
    render json: { sent: true, queued: true, kind: kind, sentry_event_id: event_id,
      message: "Queued for delivery to Sentry. Check your phone in a minute or two; see docs/MONITORING_SETUP.md." }
  end

  private

  # True when the SDK will actually send in this process: initialized, a DSN,
  # and this environment is in SENTRY_ENABLED_ENVIRONMENTS.
  def sentry_sending?
    Sentry.initialized? && Sentry.configuration.sending_allowed?
  rescue StandardError
    false
  end

  def too_soon
    response.set_header("Retry-After", MonitoringTestAlert::COOLDOWN.to_i.to_s)
    render json: { error: "A test alert was just sent. Wait a moment before sending another." }, status: :too_many_requests
  end
end
