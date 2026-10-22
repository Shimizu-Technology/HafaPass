# frozen_string_literal: true

class Api::V1::Admin::PrivacyRequestsController < Api::V1::Admin::BaseController
  before_action :set_item, except: [:index]

  def index
    response.headers["Cache-Control"] = "private, no-store"
    render json: { requests: PrivacyRequest.order(created_at: :desc).limit(200)
      .as_json(only: [:id, :kind, :status, :requester_email, :user_id, :order_id, :created_at, :verified_at,
        :executed_at, :result]) }
  end

  def show
    response.headers["Cache-Control"] = "private, no-store"
    render json: { request: serialized, preview: PrivacyRequestProcessor.new(@item).preview }
  end

  def verify
    if @item.verified?
      return render json: { request: serialized }
    end
    if @item.user && !ClerkIdentity.verified_email_addresses(@item.user.clerk_id,
        require_available: true).include?(@item.requester_email.downcase)
      return render json: { error: "Clerk does not verify this email for the account" }, status: :unprocessable_entity
    end
    @item.update!(status: "verified", verified_at: Time.current, verified_by: current_user)
    AuditLogger.record!(action: "privacy_request.verified", auditable: @item, actor: current_user,
      metadata: { kind: @item.kind, proof: @item.user ? "clerk_verified_email" : "guest_order_link" }, request: request)
    render json: { request: serialized }
  end

  def execute
    PrivacyRequestProcessor.new(@item).execute!(actor: current_user, request: request)
    render json: { request: serialized }
  rescue PrivacyRequestProcessor::Blocked => error
    render json: { error: error.message }, status: :conflict
  end

  def export
    return render json: { error: "Verify an access request first" }, status: :forbidden unless @item.kind == "access" && @item.verified?

    response.headers["Cache-Control"] = "private, no-store"
    send_data JSON.pretty_generate(PrivacyRequestProcessor.new(@item).export), type: "application/json",
      disposition: "attachment", filename: "hafapass-data-#{@item.id}.json"
  end

  private

  def set_item
    @item = PrivacyRequest.find(params[:id])
  end

  def serialized
    @item.as_json(only: [:id, :kind, :status, :requester_email, :user_id, :order_id, :created_at,
      :verified_at, :executed_at, :result])
  end
end
