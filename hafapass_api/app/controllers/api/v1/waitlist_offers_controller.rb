# frozen_string_literal: true

class Api::V1::WaitlistOffersController < ApplicationController
  skip_before_action :authenticate_user!

  def show
    offer = WaitlistCredential.find_offer(params[:token])
    return render json: { error: "Waitlist offer not found" }, status: :not_found unless offer&.active?

    render json: {
      event_slug: offer.event.slug,
      ticket_type_id: offer.ticket_type_id,
      ticket_type_name: offer.ticket_type.name,
      quantity: offer.quantity,
      unit_price_cents: offer.unit_price_cents,
      expires_at: offer.expires_at
    }
  end
end
