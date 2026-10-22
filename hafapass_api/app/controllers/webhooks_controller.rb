# frozen_string_literal: true

class WebhooksController < ActionController::API
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
    Sentry.capture_exception(e)
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
      render json: { error: "Invalid signature" }, status: :bad_request
      nil
    elsif signature.present? && any_webhook_secret?
      # Signed, but no secret is configured for this event's mode.
      render json: { error: "Webhook secret not configured for this Stripe mode" }, status: :bad_request
      nil
    elsif Rails.env.development? || Rails.env.test?
      Rails.logger.warn({ event: "unsigned_stripe_webhook", environment: Rails.env }.to_json)
      Stripe::Event.construct_from(JSON.parse(payload, symbolize_names: true))
    elsif any_webhook_secret?
      render json: { error: "Stripe signature missing" }, status: :bad_request
      nil
    else
      render json: { error: "Webhook secret not configured" }, status: :bad_request
      nil
    end
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
