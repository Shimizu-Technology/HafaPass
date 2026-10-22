# frozen_string_literal: true

class Api::V1::PlatformInvitationsController < ApplicationController
  def accept
    invitation = PlatformInvitations.accept!(token: params[:token], user: current_user, request: request)
    render json: {
      role: current_user.reload.role,
      invited_role: invitation.role,
      role_label: OrganizationRoles.platform_label(invitation.role),
      role_description: OrganizationRoles.platform_description(invitation.role)
    }
  rescue PlatformInvitations::InvitationError => e
    render json: { error: e.message }, status: :unprocessable_entity
  end
end
