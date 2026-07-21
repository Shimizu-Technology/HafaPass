# frozen_string_literal: true

class Api::V1::VenuesController < ApplicationController
  include Paginatable
  skip_before_action :authenticate_user!

  def index
    venues = Venue.published.joins(:events).merge(Event.discoverable).distinct.order(:name)
    venues = venues.where("venues.village ILIKE ?", params[:village].to_s.strip) if params[:village].present?
    pagy, records = paginate(venues)
    render json: { venues: records.map { |venue| venue_json(venue) }, meta: pagination_meta(pagy) }
  end

  def show
    venue = Venue.published.find_by!(slug: params[:slug])
    events = venue.events.merge(Event.discoverable).includes(:venue, :organization, :organizer_profile,
      ticket_types: [:inventory_holds, :waitlist_offers,
        { event_seats: :active_precheckout_seat_holds },
        { pricing_tiers: [:inventory_holds, :waitlist_offers, :active_precheckout_seat_holds] }]).order(:starts_at)
    pagy, records = paginate(events)
    render json: venue_json(venue).merge(
      events: records.map { |event| Marketplace::EventSerializer.call(event, purchasable: true) },
      meta: pagination_meta(pagy)
    )
  end

  private

  def venue_json(venue)
    venue.as_json(only: [:id, :name, :slug, :address, :village, :description, :website_url,
      :accessibility_notes, :verified])
  end
end
