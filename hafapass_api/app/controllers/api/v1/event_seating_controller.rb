# frozen_string_literal: true

class Api::V1::EventSeatingController < ApplicationController
  skip_before_action :authenticate_user!
  before_action :optional_authenticate_user!
  before_action :set_event

  def show
    configuration = @event.event_seating_configuration
    return render json: { error: "Assigned seating is not active" }, status: :not_found unless configuration&.status_active?

    render json: Seating::MapPresenter.call(configuration)
  end

  def create_hold
    result = Seating::HoldAllocator.call(
      event: @event,
      event_seat_ids: params[:event_seat_ids],
      accessibility_attested: params[:accessibility_attested],
      user: @current_user,
      source: params[:source].presence || "online"
    )
    render json: {
      token: result.token,
      expires_at: result.session.expires_at,
      event_seats: result.session.event_seats.includes(venue_seat: { seating_row: :seating_section }).map { |seat|
        { id: seat.id, display_label: seat.display_label, ticket_type_id: seat.ticket_type_id }
      }
    }, status: :created
  rescue Seating::HoldAllocator::HoldError => e
    render json: { error: e.message }, status: :unprocessable_entity
  end

  def destroy_hold
    session = Seating::Credential.find_session(params[:token])
    unless session&.event_seating_configuration&.event_id == @event.id
      return render json: { error: "Seat hold not found" }, status: :not_found
    end

    Seating::SessionLifecycle.release!(session, reason: "buyer_released")
    render json: { status: session.reload.status }
  end

  private

  def set_event
    @event = Event.published.find_by!(slug: params[:slug])
  end
end
