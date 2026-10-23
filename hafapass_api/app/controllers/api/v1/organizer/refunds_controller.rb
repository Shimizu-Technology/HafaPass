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

          options = {}
          if params.key?(:cash_return)
            evidence = params[:cash_return]
            options[:cash_return] = evidence.respond_to?(:permit) ? evidence.permit(:reference, :returned_at).to_h : {}
          end
          refund = Commerce::RefundCreator.call(
            order: @order,
            amount_cents: params[:amount_cents],
            reason: params[:reason],
            requested_by: current_user,
            idempotency_key: idempotency_key,
            **options
          )

          render json: refund_json(refund), status: :created
        rescue Commerce::RefundCreator::RefundError => e
          outcome = Commerce::RefundOutcome.call(order: @order, idempotency_key: request.headers["Idempotency-Key"])
          render json: { error: e.message }.merge(outcome), status: :unprocessable_entity
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
            provider: refund.provider,
            manual_record: refund.provider_payload["manual_record"] == true,
            cash_return: refund.provider_payload["cash_return"],
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
          }.merge(Commerce::RefundOutcome.call(order: refund.order, idempotency_key: refund.idempotency_key))
        end
      end
    end
  end
end
