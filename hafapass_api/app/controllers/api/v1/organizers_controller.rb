# frozen_string_literal: true

class Api::V1::OrganizersController < ApplicationController
  include Paginatable
  skip_before_action :authenticate_user!

  def index
    organizations = Organization.status_active.joins(:organizer_profile, :events).includes(:organizer_profile)
      .merge(Event.discoverable).distinct.order(:name)
    pagy, records = paginate(organizations)
    preload_metrics(records)
    render json: { organizers: records.map { |organization| organizer_json(organization) }, meta: pagination_meta(pagy) }
  end

  def show
    organization = Organization.status_active.includes(:organizer_profile).find_by!(slug: params[:slug])
    events = organization.events.merge(Event.discoverable).includes(:venue, :organization, :organizer_profile,
      ticket_types: [:inventory_holds, :waitlist_offers,
        { event_seats: :active_precheckout_seat_holds },
        { pricing_tiers: [:inventory_holds, :waitlist_offers, :active_precheckout_seat_holds] }]).order(:starts_at)
    pagy, records = paginate(events)
    render json: organizer_json(organization).merge(
      events: records.map { |event| Marketplace::EventSerializer.call(event, purchasable: true) },
      meta: pagination_meta(pagy)
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
      completed_events: metric_for(@completed_events, organization.id) { organization.events.completed.count },
      tickets_issued: metric_for(@tickets_issued, organization.id) {
        Ticket.joins(:event).where(events: { organization_id: organization.id }).count
      },
      followers: metric_for(@followers, organization.id) { organization.organizer_follows.count }
    }
  end

  def preload_metrics(organizations)
    ids = organizations.map(&:id)
    @completed_events = Event.completed.where(organization_id: ids).group(:organization_id).count
    @tickets_issued = Ticket.joins(:event).where(events: { organization_id: ids }).group("events.organization_id").count
    @followers = OrganizerFollow.where(organization_id: ids).group(:organization_id).count
  end

  def metric_for(metrics, organization_id)
    return yield unless metrics

    metrics.fetch(organization_id, 0)
  end
end
