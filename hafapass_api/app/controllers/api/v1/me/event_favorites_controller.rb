# frozen_string_literal: true

class Api::V1::Me::EventFavoritesController < ApplicationController
  include Paginatable

  def index
    events = current_user.favorite_events.merge(Event.publicly_visible).includes(:venue, :organization,
      :organizer_profile, ticket_types: :pricing_tiers).order(:starts_at)
    pagy, records = paginate(events)
    render json: { events: records.map { |event| Marketplace::EventSerializer.call(event) }, meta: pagination_meta(pagy) }
  end

  def create
    event = Event.publicly_visible.find(params[:event_id])
    favorite = current_user.event_favorites.find_or_create_by!(event: event)
    render json: { id: favorite.id, event_id: event.id }, status: :created
  end

  def destroy
    current_user.event_favorites.find_by!(event_id: params[:event_id]).destroy!
    head :no_content
  end
end
