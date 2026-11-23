# frozen_string_literal: true

module Api
  module V1
    module Organizer
      class RefundsController < BaseController
        before_action :set_event
        before_action :authorize_refund_options, only: :options
        before_action :set_order

        def options
          render json: Commerce::OrganizerRefundOptions.call(@order)
        end

        def create
          idempotency_key = request.headers["Idempotency-Key"].presence
          raise Commerce::RefundCreator::RefundError, "Idempotency-Key header is required" unless idempotency_key

          tickets = selected_tickets
          if tickets && @order.total_cents.zero?
            raise Commerce::RefundCreator::RefundError, "A free order cannot record a cash return" if params.key?(:cash_return)

            result = Commerce::FreeTicketCancellation.call(order: @order, tickets: tickets, actor: current_user,
              reason: params[:reason], idempotency_key: idempotency_key)
            outcome = Commerce::RefundOutcome.call(order: @order, idempotency_key: idempotency_key)
            return render json: result.merge(outcome), status: :created
          end

          cash_return = nil
          if params.key?(:cash_return)
            evidence = params[:cash_return]
            cash_return = evidence.respond_to?(:permit) ? evidence.permit(:reference, :returned_at).to_h : {}
          end
          refund = Commerce::RefundCreator.call(
            order: @order,
            amount_cents: params[:amount_cents],
            reason: params[:reason],
            requested_by: current_user,
            idempotency_key: idempotency_key,
            organizer_initiated: true,
            cash_return: cash_return,
            tickets: tickets,
            preserve_tickets: params[:preserve_tickets] == true
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

        def authorize_refund_options
          authorize_organization!(:view_finance, event: @event)
        end

        def set_order
          @order = @event.orders.find(params[:order_id] || params[:id])
        rescue ActiveRecord::RecordNotFound
          render json: { error: "Order not found" }, status: :not_found
        end

        def selected_tickets
          return unless params.key?(:ticket_ids)

          error = Commerce::RefundCreator::RefundError
          raise error, "Choose a refund amount or tickets" if params.key?(:amount_cents)

          ids = params[:ticket_ids]
          unless ids.is_a?(Array) && ids.any? && ids.all? { |id| id.is_a?(Integer) && id.positive? }
            raise error, "Choose at least one ticket using integer ticket IDs"
          end

          tickets = @order.tickets.where(id: ids).to_a
          raise error, "Ticket not found for this order" unless tickets.size == ids.uniq.size

          tickets
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
