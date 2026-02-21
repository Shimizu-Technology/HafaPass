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

          # Validate ticket types exist (availability checked inside transaction with locking)
          ticket_selections = []
          line_items.each do |item|
            ticket_type = @event.ticket_types.find_by(id: item[:ticket_type_id])
            unless ticket_type
              render json: { error: "Ticket type #{item[:ticket_type_id]} not found" }, status: :unprocessable_entity
              return
            end

            quantity = item[:quantity].to_i
            if quantity <= 0
              render json: { error: "Invalid quantity for #{ticket_type.name}" }, status: :unprocessable_entity
              return
            end

            ticket_selections << { ticket_type: ticket_type, quantity: quantity }
          end

          availability_error = nil

          ActiveRecord::Base.transaction do
            # Re-check availability with pessimistic locking to prevent overselling
            ticket_selections.each do |selection|
              locked_tt = TicketType.lock.find(selection[:ticket_type].id)
              if selection[:quantity] > locked_tt.available_quantity
                availability_error = "Not enough tickets for #{locked_tt.name}. Available: #{locked_tt.available_quantity}"
                raise ActiveRecord::Rollback
              end
              selection[:ticket_type] = locked_tt
            end

            next if availability_error

            subtotal_cents = ticket_selections.sum { |s| s[:ticket_type].price_cents * s[:quantity] }
            @order = Order.create!(
              user: current_user,
              event: @event,
              status: :completed,
              subtotal_cents: subtotal_cents,
              service_fee_cents: 0,
              discount_cents: 0,
              total_cents: subtotal_cents,
              buyer_email: buyer_email,
              buyer_name: buyer_name,
              buyer_phone: params[:buyer_phone],
              completed_at: Time.current,
              source: "box_office",
              payment_method: payment_method
            )

            ticket_selections.each do |selection|
              selection[:quantity].times do
                @order.tickets.create!(
                  ticket_type: selection[:ticket_type],
                  event: @event,
                  attendee_name: buyer_name,
                  attendee_email: buyer_email
                )
              end
              selection[:ticket_type].increment!(:quantity_sold, selection[:quantity])
            end
          end

          if availability_error
            render json: { error: availability_error }, status: :unprocessable_entity
            return
          end

          render json: order_json(@order), status: :created
        rescue ActiveRecord::RecordInvalid => e
          render json: { error: e.message }, status: :unprocessable_entity
        end

        # GET /api/v1/organizer/events/:event_id/box_office/summary
        def summary
          orders = @event.orders.where(source: "box_office")
          completed_orders = orders.where(status: :completed)

          render json: {
            total_orders: completed_orders.count,
            total_revenue_cents: completed_orders.sum(:total_cents),
            total_tickets: @event.tickets.joins(:order).where(orders: { source: "box_office" }).where.not(tickets: { status: :cancelled }).count,
            by_payment_method: {
              door_cash: completed_orders.where(payment_method: "door_cash").sum(:total_cents),
              door_card: completed_orders.where(payment_method: "door_card").sum(:total_cents)
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
