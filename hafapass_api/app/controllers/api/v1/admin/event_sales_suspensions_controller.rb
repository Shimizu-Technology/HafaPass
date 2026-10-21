# frozen_string_literal: true

class Api::V1::Admin::EventSalesSuspensionsController < Api::V1::Admin::BaseController
  # DELETE /api/v1/admin/events/:event_id/sales_suspension ("Resume sales")
  def destroy
    event = Event.find(params[:event_id])
    EventSalesSuspension.lift!(event: event, actor: current_user, note: params[:note], request: request)
    render json: { id: event.id, sales_suspended: false, sales_status: event.reload.sales_status }
  rescue ActiveRecord::RecordNotFound
    render json: { error: "Event not found" }, status: :not_found
  rescue EventSalesSuspension::SuspensionError => e
    render json: { error: e.message }, status: :unprocessable_entity
  end
end
