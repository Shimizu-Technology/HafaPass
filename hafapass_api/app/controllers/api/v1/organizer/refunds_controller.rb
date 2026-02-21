module Api
  module V1
    module Organizer
      class RefundsController < ApplicationController
        before_action :require_organizer_profile
        before_action :set_event
        before_action :set_order

        # POST /api/v1/organizer/events/:event_id/orders/:order_id/refund
        # Supports full and partial refunds. Respects simulate/test/live modes.
        def create
          unless @order.completed? || @order.partially_refunded?
            render json: { error: "Only completed or partially refunded orders can be refunded" }, status: :unprocessable_entity
            return
          end

          amount_cents = params[:amount_cents]&.to_i
          reason = params[:reason]

          # Validate refund amount
          max_refundable = @order.total_cents - @order.refund_amount_cents
          if amount_cents
            if amount_cents <= 0
              render json: { error: "Refund amount must be positive" }, status: :unprocessable_entity
              return
            end
            if amount_cents > max_refundable
              render json: { error: "Refund amount exceeds refundable balance ($#{'%.2f' % (max_refundable / 100.0)})" }, status: :unprocessable_entity
              return
            end
          else
            amount_cents = max_refundable  # Full refund
          end

          is_full_refund = amount_cents >= max_refundable

          begin
            # Process refund through StripeService (respects simulate/test/live)
            if @order.stripe_payment_intent_id.present? && @order.stripe_payment_intent_id !~ /^sim_/
              refund = StripeService.refund_payment(
                @order.stripe_payment_intent_id,
                amount_cents: is_full_refund ? nil : amount_cents,
                reason: reason
              )
              stripe_refund_id = refund.id
            else
              # Simulated payment — just log it
              Rails.logger.info("[Refund SIMULATE] Order ##{@order.id}: $#{'%.2f' % (amount_cents / 100.0)}")
              stripe_refund_id = "sim_re_#{SecureRandom.hex(12)}"
            end

            ActiveRecord::Base.transaction do
              new_refund_total = @order.refund_amount_cents + amount_cents

              @order.update!(
                status: is_full_refund ? :refunded : :partially_refunded,
                refund_amount_cents: new_refund_total,
                refund_reason: reason,
                refunded_at: Time.current,
                stripe_refund_id: stripe_refund_id
              )

              # Cancel tickets on full refund
              if is_full_refund
                @order.tickets.includes(:ticket_type).each do |ticket|
                  next if ticket.cancelled?
                  ticket.ticket_type.decrement!(:quantity_sold)
                  ticket.update!(status: :cancelled)
                end
              end
            end

            # Send refund email asynchronously
            EmailService.send_refund_notification_async(@order)

            # Notify waitlisted people if tickets became available
            @event.notify_waitlist_if_available if is_full_refund

            render json: {
              id: @order.id,
              status: @order.status,
              refund_amount_cents: @order.refund_amount_cents,
              refund_reason: @order.refund_reason,
              refunded_at: @order.refunded_at,
              stripe_refund_id: stripe_refund_id,
              total_cents: @order.total_cents,
              remaining_cents: @order.total_cents - @order.refund_amount_cents
            }
          rescue Stripe::StripeError, StripeService::PaymentError => e
            render json: { error: "Refund failed: #{e.message}" }, status: :unprocessable_entity
          end
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

        def set_order
          @order = @event.orders.find(params[:order_id])
        rescue ActiveRecord::RecordNotFound
          render json: { error: "Order not found" }, status: :not_found
        end
      end
    end
  end
end
