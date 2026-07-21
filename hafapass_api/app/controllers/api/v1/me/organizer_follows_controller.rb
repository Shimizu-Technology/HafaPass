# frozen_string_literal: true

class Api::V1::Me::OrganizerFollowsController < ApplicationController
  def index
    render json: { organizers: current_user.followed_organizations.includes(:organizer_profile).order(:name).map { |org|
      { id: org.id, name: org.organizer_profile.business_name, slug: org.slug, logo_url: org.organizer_profile.logo_url,
        verified: org.organizer_profile.verification_status_verified? }
    } }
  end

  def create
    organization = Organization.status_active.find(params[:organization_id])
    follow = current_user.organizer_follows.find_or_create_by!(organization: organization)
    render json: { id: follow.id, organization_id: organization.id }, status: :created
  end

  def destroy
    current_user.organizer_follows.find_by!(organization_id: params[:organization_id]).destroy!
    head :no_content
  end
end
