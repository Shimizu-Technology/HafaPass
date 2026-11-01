# frozen_string_literal: true

class Api::V1::GuestPrivacyRequestsController < ApplicationController
  skip_before_action :authenticate_user!

  def create
    kind = params[:kind].to_s
    order = GuestOrderAccess.find(params[:guest_token])
    unless PrivacyRequest::KINDS.include?(kind) && order && order.id.to_s == params[:order_id].to_s
      return render json: { error: "A current verified order link is required" }, status: :forbidden
    end

    # The request, its code email and the audit entry commit together. If the
    # send fails or times out, nothing is kept: no unaudited request is left
    # behind, and a retry starts a fresh request with a fresh code. (A code
    # that reached the inbox despite a timeout belongs to the rolled-back
    # request and can never verify anything.) Each HTTP phase is bounded by
    # the 10-second timeouts in config/initializers/resend.rb, and the whole
    # provider call by EmailService::GUEST_CHALLENGE_SEND_DEADLINE, so a
    # slowly trickling response still ends in the retryable 503 below.
    item = PrivacyRequest.transaction(requires_new: true) do
      created = PrivacyRequest.create!(kind: kind, order: order, requester_email: order.buyer_email,
        verified_emails: [order.buyer_email.to_s.downcase])
      code = created.issue_guest_challenge!
      EmailService.send_guest_privacy_challenge_now(created, code)
      AuditLogger.record!(action: "privacy_request.submitted", auditable: created,
        metadata: { kind: kind, guest: true }, request: request)
      created
    end
    render json: item.as_json(only: [:id, :kind, :status, :created_at]), status: :created
  rescue Timeout::Error
    response.set_header("Retry-After", "60")
    render json: { error: "We couldn't send your code right now. Try again in a minute.", retryable: true },
      status: :service_unavailable
  end

  def verify
    item = PrivacyRequest.find_by(id: params[:id], user_id: nil)
    return render json: { error: "Invalid or expired challenge" }, status: :forbidden unless
      item&.verify_guest_challenge!(params[:code])

    AuditLogger.record!(action: "privacy_request.verified", auditable: item,
      metadata: { kind: item.kind, proof: "guest_email_challenge" }, request: request)
    render json: { status: item.status }
  end
end
