# frozen_string_literal: true

class Api::V1::Admin::VenuesController < Api::V1::Admin::BaseController
  def index
    render json: { venues: Venue.order(:name).map { |venue| serialize(venue) } }
  end

  def create
    persist(Venue.new(venue_params), :created)
  end

  def update
    venue = Venue.find(params[:id])
    venue.assign_attributes(venue_params)
    persist(venue)
  end

  def destroy
    Venue.find(params[:id]).update!(active: false)
    head :no_content
  end

  private

  def venue_params
    params.permit(:name, :slug, :address, :village, :description, :website_url, :accessibility_notes,
      :verified, :active)
  end

  def persist(venue, status = :ok)
    if venue.save
      render json: serialize(venue), status: status
    else
      render json: { errors: venue.errors.full_messages }, status: :unprocessable_entity
    end
  end

  def serialize(venue)
    venue.as_json.merge(upcoming_event_count: venue.events.merge(Event.discoverable).count)
  end
end
