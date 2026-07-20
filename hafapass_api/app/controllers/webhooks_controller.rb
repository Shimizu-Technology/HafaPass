# frozen_string_literal: true

class WebhooksController < ActionController::API
  def stripe
    payload = request.body.read
    event = verified_stripe_event(payload)
    return unless event

    StripeWebhookProcessor.call(event: event, payload: JSON.parse(payload))
    render json: { received: true }, status: :ok
  rescue JSON::ParserError
    render json: { error: "Invalid payload" }, status: :bad_request
  rescue StandardError => e
    Sentry.capture_exception(e)
    render json: { error: "Webhook processing failed" }, status: :internal_server_error
  end

  private

  def verified_stripe_event(payload)
    signature = request.env["HTTP_STRIPE_SIGNATURE"]
    secret = ENV["STRIPE_WEBHOOK_SECRET"]

    if secret.present? && signature.present?
      Stripe::Webhook.construct_event(payload, signature, secret)
    elsif Rails.env.development? || Rails.env.test?
      Rails.logger.warn({ event: "unsigned_stripe_webhook", environment: Rails.env }.to_json)
      Stripe::Event.construct_from(JSON.parse(payload, symbolize_names: true))
    else
      render json: { error: "Webhook secret not configured" }, status: :bad_request
      nil
    end
  rescue Stripe::SignatureVerificationError
    render json: { error: "Invalid signature" }, status: :bad_request
    nil
  end
end
