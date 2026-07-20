# frozen_string_literal: true

module Api
  module V1
    module Organizer
      class BoxOfficeController < ApplicationController
        before_action :require_organizer_profile
        before_action :set_event

        # POST /api/v1/organizer/events/:event_id/box_office
        def create
          line_items = params[:line_items]
          unless line_items.is_a?(Array) && line_items.any?
            render json: { error: "line_items is required" }, status: :unprocessable_entity
            return
          end

          payment_method = params[:payment_method]
          unless %w[door_cash door_card].include?(payment_method)
            render json: { error: "payment_method must be 'door_cash' or 'door_card'" }, status: :unprocessable_entity
            return
          end

          buyer_name = params[:buyer_name].presence || "Walk-in"
          buyer_email = params[:buyer_email].presence || "walkin-#{SecureRandom.hex(4)}@boxoffice.local"

          result = Commerce::OrderCreator.call(
            event: @event,
            line_items: line_items,
            buyer_email: buyer_email,
            buyer_name: buyer_name,
            buyer_phone: params[:buyer_phone],
            user: current_user,
            payment_required: false,
            service_fee: false,
            source: "box_office",
            payment_method: payment_method
          )

          render json: order_json(result.order), status: :created
        rescue Commerce::OrderCreator::CheckoutError => e
          render json: { error: e.message }, status: :unprocessable_entity
        end

        # GET /api/v1/organizer/events/:event_id/box_office/summary
        def summary
          orders = @event.orders.where(source: "box_office")
          settled_orders = orders.where(status: [:completed, :partially_refunded, :refunded])
          financials = Commerce::LedgerTotals.call(settled_orders)

          render json: {
            total_orders: settled_orders.count,
            total_revenue_cents: financials[:net_cents],
            total_tickets: @event.tickets.joins(:order).where(orders: { source: "box_office" }).where.not(tickets: { status: :cancelled }).count,
            by_payment_method: {
              door_cash: Commerce::LedgerTotals.call(settled_orders.where(payment_method: "door_cash"))[:net_cents],
              door_card: Commerce::LedgerTotals.call(settled_orders.where(payment_method: "door_card"))[:net_cents]
            }
          }
        end

        private

        def require_organizer_profile
          unless current_organizer_profile
            render json: { error: "Organizer profile required" }, status: :forbidden
          end
        end

        def current_organizer_profile
          @current_organizer_profile ||= current_user.organizer_profile
        end

        def set_event
          @event = current_organizer_profile.events.find(params[:event_id])
        rescue ActiveRecord::RecordNotFound
          render json: { error: "Event not found" }, status: :not_found
        end

        def order_json(order)
          {
            id: order.id,
            event_id: order.event_id,
            status: order.status,
            total_cents: order.total_cents,
            buyer_name: order.buyer_name,
            buyer_email: order.buyer_email,
            source: order.source,
            payment_method: order.payment_method,
            completed_at: order.completed_at,
            tickets: order.tickets.includes(:ticket_type).map { |t|
              {
                id: t.id,
                qr_code: t.qr_code,
                status: t.status,
                attendee_name: t.attendee_name,
                ticket_type: { id: t.ticket_type.id, name: t.ticket_type.name, price_cents: t.ticket_type.price_cents }
              }
            }
          }
        end
      end
    end
  end
end
