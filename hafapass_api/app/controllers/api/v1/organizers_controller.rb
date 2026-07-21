# frozen_string_literal: true

class Api::V1::OrganizersController < ApplicationController
  include Paginatable
  skip_before_action :authenticate_user!

  def index
    organizations = Organization.status_active.joins(:organizer_profile, :events)
      .merge(Event.discoverable).distinct.order(:name)
    pagy, records = paginate(organizations)
    render json: { organizers: records.map { |organization| organizer_json(organization) }, meta: pagination_meta(pagy) }
  end

  def show
    organization = Organization.status_active.includes(:organizer_profile).find_by!(slug: params[:slug])
    events = organization.events.merge(Event.discoverable).includes(:venue, :organization, :organizer_profile,
      ticket_types: :pricing_tiers).order(:starts_at)
    pagy, records = paginate(events)
    render json: organizer_json(organization).merge(
      events: records.map { |event| Marketplace::EventSerializer.call(event) }, meta: pagination_meta(pagy)
    )
  end

  private

  def organizer_json(organization)
    profile = organization.organizer_profile
    {
      id: organization.id,
      name: profile.business_name,
      slug: organization.slug,
      description: profile.business_description,
      logo_url: profile.logo_url,
      verified: profile.verification_status_verified?,
      ambros_partner: profile.is_ambros_partner,
      completed_events: organization.events.completed.count,
      tickets_issued: Ticket.joins(:event).where(events: { organization_id: organization.id }).count,
      followers: organization.organizer_follows.count
    }
  end
end
