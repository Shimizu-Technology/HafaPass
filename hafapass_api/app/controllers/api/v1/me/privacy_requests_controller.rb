# frozen_string_literal: true

class Api::V1::Me::PrivacyRequestsController < ApplicationController
  def index
    response.headers["Cache-Control"] = "private, no-store"
    render json: { requests: PrivacyRequest.where(user_id: current_user.id).order(created_at: :desc)
      .map { |item| item.as_json(only: [:id, :kind, :status, :created_at, :executed_at, :result]) } }
  end

  def create
    kind = params[:kind].to_s
    return render json: { error: "Choose access or deletion" }, status: :unprocessable_entity unless PrivacyRequest::KINDS.include?(kind)

    emails = ClerkIdentity.verified_email_addresses(current_user.clerk_id, require_available: true)
    email = emails.include?(current_user.email.to_s.downcase) ? current_user.email.downcase : emails.first
    return render json: { error: "Verify an email address in your account first" }, status: :unprocessable_entity if email.blank?

    item = PrivacyRequest.create!(kind: kind, user: current_user, requester_email: email)
    AuditLogger.record!(action: "privacy_request.submitted", auditable: item, actor: current_user,
      metadata: { kind: kind }, request: request)
    render json: item.as_json(only: [:id, :kind, :status, :created_at]), status: :created
  end
end
