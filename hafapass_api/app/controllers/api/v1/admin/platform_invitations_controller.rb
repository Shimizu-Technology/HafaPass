# frozen_string_literal: true

class Api::V1::Admin::PlatformInvitationsController < Api::V1::Admin::BaseController
  before_action :set_invitation, only: [:resend, :destroy]

  def index
    invitations = PlatformInvitation.includes(:invited_by_user, :accepted_by_user).order(created_at: :desc).limit(50)
    render json: { invitations: invitations.map { |invitation| invitation_json(invitation) } }
  end

  def create
    invitation = PlatformInvitations.invite!(email: params[:email], role: params[:role], actor: current_user,
      request: request)
    render json: invitation_json(invitation), status: :created
  rescue PlatformInvitations::InvitationError => e
    render json: { error: e.message }, status: :unprocessable_entity
  end

  def resend
    PlatformInvitations.resend!(invitation: @invitation, actor: current_user, request: request)
    render json: invitation_json(@invitation.reload)
  rescue PlatformInvitations::InvitationError => e
    render json: { error: e.message }, status: :unprocessable_entity
  end

  def destroy
    PlatformInvitations.revoke!(invitation: @invitation, actor: current_user, request: request)
    render json: invitation_json(@invitation.reload)
  rescue PlatformInvitations::InvitationError => e
    render json: { error: e.message }, status: :unprocessable_entity
  end

  private

  def set_invitation
    @invitation = PlatformInvitation.find(params[:id])
  rescue ActiveRecord::RecordNotFound
    render json: { error: "Invitation not found" }, status: :not_found
  end

  # The accept link is the copy fallback when email is unavailable; it is
  # only shown to admins and only while the invitation is open.
  def invitation_json(invitation)
    json = PlatformInvitations.invitation_json(invitation)
    json[:accept_url] = PlatformInvitations.accept_url(invitation) if json[:status] == "pending"
    json
  end
end
