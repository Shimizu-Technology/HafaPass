# frozen_string_literal: true

class Api::V1::OrganizationInvitationsController < ApplicationController
  around_action :with_audit_transaction, only: :accept
  def accept
    membership = OrganizationInvitation.accept!(token: params[:token], user: current_user)
    render json: {
      organization_id: membership.organization_id,
      organization_name: membership.organization.name,
      role: membership.role,
      role_label: OrganizationRoles.label(membership.role),
      role_description: OrganizationRoles.description(membership.role),
      status: membership.status,
      events: membership.organization.events.where(
        id: membership.organization.event_staff_assignments.effective.where(user: current_user).select(:event_id)
      ).order(:starts_at).map { |event| { id: event.id, title: event.title } }
    }
  rescue OrganizationInvitation::InvitationError => e
    render json: { error: e.message }, status: :unprocessable_entity
  end
end
