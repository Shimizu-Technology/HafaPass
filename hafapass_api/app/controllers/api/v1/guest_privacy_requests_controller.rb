# frozen_string_literal: true

class Api::V1::GuestPrivacyRequestsController < ApplicationController
  skip_before_action :authenticate_user!

  def create
    kind = params[:kind].to_s
    order = GuestOrderAccess.find(params[:guest_token])
    unless PrivacyRequest::KINDS.include?(kind) && order && order.id.to_s == params[:order_id].to_s
      return render json: { error: "A current verified order link is required" }, status: :forbidden
    end

    item = PrivacyRequest.create!(kind: kind, order: order, requester_email: order.buyer_email,
      verified_emails: [order.buyer_email.to_s.downcase])
    code = item.issue_guest_challenge!
    EmailService.send_guest_privacy_challenge_now(item, code)
    AuditLogger.record!(action: "privacy_request.submitted", auditable: item,
      metadata: { kind: kind, guest: true }, request: request)
    render json: item.as_json(only: [:id, :kind, :status, :created_at]), status: :created
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
