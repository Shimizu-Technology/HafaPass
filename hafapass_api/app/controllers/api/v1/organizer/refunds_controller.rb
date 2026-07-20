# frozen_string_literal: true

module Api
  module V1
    module Organizer
      class RefundsController < BaseController
        before_action :set_event
        before_action :set_order

        def create
          idempotency_key = request.headers["Idempotency-Key"].presence
          unless idempotency_key
            render json: { error: "Idempotency-Key header is required" }, status: :unprocessable_entity
            return
          end

          refund = Commerce::RefundCreator.call(
            order: @order,
            amount_cents: params[:amount_cents],
            reason: params[:reason],
            requested_by: current_user,
            idempotency_key: idempotency_key
          )

          AuditLogger.record!(
            action: "refund.created",
            auditable: refund,
            actor: current_user,
            organization: current_organization,
            metadata: { order_id: @order.id, amount_cents: refund.amount_cents },
            request: request
          )

          render json: refund_json(refund), status: :created
        rescue Commerce::RefundCreator::RefundError => e
          render json: { error: e.message }, status: :unprocessable_entity
        end

        private

        def set_event
          @event = find_organization_event(params[:event_id])
          authorize_organization!(:refund, event: @event) if @event
        end

        def set_order
          @order = @event.orders.find(params[:order_id] || params[:id])
        rescue ActiveRecord::RecordNotFound
          render json: { error: "Order not found" }, status: :not_found
        end

        def refund_json(refund)
          {
            id: refund.id,
            order_id: refund.order_id,
            status: refund.status,
            amount_cents: refund.amount_cents,
            currency: refund.currency,
            reason: refund.reason,
            provider_refund_id: refund.provider_refund_id,
            succeeded_at: refund.succeeded_at,
            refunded_total_cents: refund.order.refunded_cents,
            remaining_cents: refund.order.refundable_cents,
            items: refund.refund_items.includes(:order_item).map { |item|
              {
                order_item_id: item.order_item_id,
                name: item.order_item.name,
                amount_cents: item.amount_cents,
                quantity: item.quantity
              }
            }
          }
        end
      end
    end
  end
end
