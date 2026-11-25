# frozen_string_literal: true

class WebhooksController < ActionController::API
  # This controller doesn't inherit ApplicationController, so it tags its own
  # Sentry scope: alert rules on area:webhook then match real errors too
  # (docs/MONITORING_SETUP.md).
  before_action { Sentry.set_tags(area: "webhook") }

  def stripe
    payload = request.body.read
    event = verified_stripe_event(payload)
    return unless event

    if Rails.env.staging? && JSON.parse(payload)["livemode"] != false
      render json: { error: "Staging accepts only signed Stripe test events" }, status: :bad_request
      return
    end

    StripeWebhookProcessor.call(event: event, payload: JSON.parse(payload))
    render json: { received: true }, status: :ok
  rescue JSON::ParserError
    render json: { error: "Invalid payload" }, status: :bad_request
  rescue StandardError => e
    Sentry.capture_exception(e, tags: { integration: "stripe_webhook", operation: "webhook_processing", area: "webhook" })
    render json: { error: "Webhook processing failed" }, status: :internal_server_error
  end

  private

  # Stripe signs test-mode and live-mode events with different endpoint
  # secrets. The (signed) livemode flag selects the secret; an event without
  # one is tried against live, then test. The verified mode is logged, and the
  # payment processor still requires it to match the payment's environment.
  def verified_stripe_event(payload)
    signature = request.env["HTTP_STRIPE_SIGNATURE"]
    candidates = webhook_secret_candidates(payload)

    if candidates.any? && signature.present?
      candidates.each do |environment, secret|
        event = Stripe::Webhook.construct_event(payload, signature, secret)
        Rails.logger.info({ event: "stripe_webhook_verified", provider_event_id: event.id, mode: environment }.to_json)
        return event
      rescue Stripe::SignatureVerificationError
        next
      end
      reject_signature!("invalid_signature", "Invalid signature", signature)
      nil
    elsif signature.present? && any_webhook_secret?
      # Signed, but no secret is configured for this event's mode.
      reject_signature!("secret_missing", "Webhook secret not configured for this Stripe mode", signature)
      nil
    elsif Rails.env.development? || Rails.env.test?
      Rails.logger.warn({ event: "unsigned_stripe_webhook", environment: Rails.env }.to_json)
      Stripe::Event.construct_from(JSON.parse(payload, symbolize_names: true))
    elsif any_webhook_secret?
      reject_signature!("signature_missing", "Stripe signature missing", signature)
      nil
    else
      reject_signature!("secret_missing", "Webhook secret not configured", signature)
      nil
    end
  end

  # A rejection stores no receipt, so count it (no payload, no headers) to make
  # a wrong or missing signing secret visible to the webhook alerts. On every
  # branch, a signature header that isn't Stripe-shaped (or is absent) is
  # internet noise, not a wrong secret. The counts are in memory and flushed in
  # one write per interval (Operations::WebhookRejections).
  def reject_signature!(reason, message, signature = nil)
    reason = "signature_missing" unless Operations::WebhookRejections.stripe_shaped?(signature)
    Operations::WebhookRejections.record!(provider: "stripe", reason: reason)
    render json: { error: message }, status: :bad_request
  end

  def any_webhook_secret?
    StripeCredentials::ENVIRONMENTS.any? { |environment| StripeCredentials.webhook_secret(environment).present? }
  end

  def webhook_secret_candidates(payload)
    livemode = begin
      JSON.parse(payload)["livemode"]
    rescue JSON::ParserError
      nil
    end
    environments = case livemode
    when true then %w[live]
    when false then %w[test]
    else %w[live test]
    end
    environments.filter_map do |environment|
      secret = StripeCredentials.webhook_secret(environment)
      [environment, secret] if secret.present?
    end
  end
end
