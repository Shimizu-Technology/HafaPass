# frozen_string_literal: true

# Platform-admin view of the monitoring that reaches Leon's phone: Stripe
# webhook health, the latest summary, and a clearly labelled test alert for
# checking Sentry rules (docs/MONITORING_SETUP.md).
class Api::V1::Admin::MonitoringController < Api::V1::Admin::BaseController
  TEST_ALERT_KINDS = MonitoringTestAlert::KINDS
  TEST_ALERT_COOLDOWN = 30.seconds
  COOLDOWN_SIGNAL = "monitoring_test_alert"

  # GET /api/v1/admin/monitoring
  def show
    response.headers["Cache-Control"] = "no-store"
    render json: {
      stripe_webhooks: Operations::StripeWebhookHealth.call,
      summary: Operations::DailySummary.call(date: params[:date]),
      sentry: { configured: ENV["SENTRY_DSN"].present?, environment: ENV.fetch("SENTRY_ENVIRONMENT", Rails.env) },
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
    return too_soon if recently_sent?

    event_id = MonitoringTestAlert.send!(kind: kind, actor: @current_user)
    AuditLogger.record!(action: "monitoring.test_alert_sent", auditable: @current_user, actor: @current_user,
      metadata: { kind: kind })
    render json: { sent: true, kind: kind, sentry_event_id: event_id,
      message: "Test alert sent. It should reach Sentry within a minute; see docs/MONITORING_SETUP.md." }
  end

  private

  # One shared cooldown (durable, so it holds across web processes), claimed
  # with a single conditional UPDATE: of two simultaneous requests, one wins.
  def recently_sent?
    now = Time.current
    begin
      RuntimeAlertState.create!(signal: COOLDOWN_SIGNAL, last_alerted_at: now)
      return false
    rescue ActiveRecord::RecordNotUnique
      nil
    end
    RuntimeAlertState.where(signal: COOLDOWN_SIGNAL)
      .where("last_alerted_at IS NULL OR last_alerted_at <= ?", now - TEST_ALERT_COOLDOWN)
      .update_all(last_alerted_at: now, updated_at: now).zero?
  end

  def too_soon
    response.set_header("Retry-After", TEST_ALERT_COOLDOWN.to_i.to_s)
    render json: { error: "A test alert was just sent. Wait a moment before sending another." }, status: :too_many_requests
  end
end
