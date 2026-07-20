# frozen_string_literal: true

class ResendWebhooksController < ActionController::API
  def create
    payload = request.raw_post
    event = ResendWebhookVerifier.verify!(payload: payload, headers: {
      "svix-id" => request.headers["svix-id"],
      "svix-timestamp" => request.headers["svix-timestamp"],
      "svix-signature" => request.headers["svix-signature"]
    })
    receipt = MessageProviderEventProcessor.call(
      provider_event_id: request.headers["svix-id"],
      event: event
    )
    render json: { received: true, id: receipt.id }
  rescue ResendWebhookVerifier::VerificationError => e
    render json: { error: e.message }, status: :bad_request
  rescue ActiveRecord::RecordNotUnique
    render json: { received: true }
  end
end
