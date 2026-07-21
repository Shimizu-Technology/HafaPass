# frozen_string_literal: true

class Api::V1::Organizer::CatalogFulfillmentsController < Api::V1::Organizer::BaseController
  def create
    event = find_organization_event(params[:event_id])
    return unless event && authorize_organization!(:manage_attendees, event: event)

    item = OrderItem.joins(:order).where(orders: { event_id: event.id }).find_by(id: params[:order_item_id])
    fulfillment = item&.catalog_fulfillment
    return render json: { error: "Fulfillment not found" }, status: :not_found unless fulfillment

    fulfillment.fulfill!(user: current_user)
    render json: { status: fulfillment.status, fulfilled_at: fulfillment.fulfilled_at }
  rescue ActiveRecord::RecordInvalid
    render json: { error: "This item cannot be fulfilled" }, status: :unprocessable_entity
  end
end
