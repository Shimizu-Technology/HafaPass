# frozen_string_literal: true

class Api::V1::Organizer::BaseController < ApplicationController
  before_action :require_current_organization

  private

  def current_organization
    @current_organization ||= OrganizationContext.resolve(
      user: current_user,
      requested_id: request.headers["X-Organization-Id"].presence || params[:organization_id].presence
    )
  end

  def current_organizer_profile
    current_organization&.organizer_profile
  end

  def require_current_organization
    return if current_organization

    render json: { error: "Organization membership required" }, status: :forbidden
  end

  def authorize_organization!(permission, event: nil)
    return true if OrganizationAuthorization.allowed?(
      user: current_user,
      organization: current_organization,
      permission: permission,
      event: event
    )

    render json: { error: "You do not have permission to perform this action" }, status: :forbidden
    false
  end

  def find_organization_event(id)
    current_organization.events.find(id)
  rescue ActiveRecord::RecordNotFound
    render json: { error: "Event not found" }, status: :not_found
    nil
  end
end
