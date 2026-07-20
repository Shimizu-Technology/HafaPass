# frozen_string_literal: true

class Api::V1::OrganizationInvitationsController < ApplicationController
  def accept
    membership = OrganizationInvitation.accept!(token: params[:token], user: current_user)
    AuditLogger.record!(
      action: "organization.invitation_accepted",
      auditable: membership,
      actor: current_user,
      organization: membership.organization,
      request: request
    )
    render json: {
      organization_id: membership.organization_id,
      organization_name: membership.organization.name,
      role: membership.role,
      status: membership.status
    }
  rescue OrganizationInvitation::InvitationError => e
    render json: { error: e.message }, status: :unprocessable_entity
  end
end
