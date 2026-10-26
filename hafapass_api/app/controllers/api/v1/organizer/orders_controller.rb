# frozen_string_literal: true

module Api
  module V1
    module Organizer
      class OrdersController < BaseController
        include Paginatable

        def index
          event = find_organization_event(params[:event_id])
          return unless event
          return unless authorize_organization!(:view_finance, event: event)
          return unless authorize_organization!(:refund, event: event)

          orders = event.orders.where(status: [:completed, :partially_refunded, :refunded])
            .includes(:tickets, :payments, :refunds).order(created_at: :desc, id: :desc)
          query = params[:q].to_s.strip.first(200)
          if query.present?
            pattern = "%#{Order.sanitize_sql_like(query)}%"
            orders = orders.where(
              "reference ILIKE :q OR buyer_name ILIKE :q OR buyer_email ILIKE :q OR CAST(orders.id AS TEXT) = :id",
              q: pattern, id: query.delete_prefix("#")
            )
          end
          pagy, records = paginate(orders, items: params.fetch(:per_page, 20).to_i.clamp(1, 100))
          verification_order_ids = external_refund_verification_order_ids(records)
          render json: {
            orders: records.map { |order| order_json(order, verification_order_ids.include?(order.id)) },
            meta: pagination_meta(pagy)
          }
        end

        private

        def external_refund_verification_order_ids(orders)
          # Reuse the page's preloaded payments, including legacy payment-only
          # exception bindings. Queue pagination must not decide refund safety.
          payment_orders = orders.flat_map { |order| order.payments.map { |payment| [payment.id, order.id] } }.to_h
          issues = ReconciliationException.open.where(code: Commerce::ExternalRefundRecovery::RECOVERABLE_CODES)
          issues.where(order_id: orders.map(&:id)).or(issues.where(payment_id: payment_orders.keys))
            .pluck(:order_id, :payment_id).flat_map { |order_id, payment_id| [order_id, payment_orders[payment_id]] }.compact.to_set
        end

        def order_json(order, verification_required)
          captured = order.payments.select { |payment| %w[succeeded partially_refunded refunded].include?(payment.status) }
          providers = captured.map(&:provider).uniq
          {
              id: order.id, reference: order.reference, buyer_name: order.buyer_name, buyer_email: order.buyer_email,
              payment_method: order.payment_method, payment_provider: providers.one? ? providers.first : nil,
              refunds: order.refunds.sort_by(&:id).reverse.map { |refund| {
                id: refund.id, provider: refund.provider, status: refund.status, amount_cents: refund.amount_cents,
                manual_record: refund.provider_payload["manual_record"] == true,
                cash_return: refund.provider_payload["cash_return"], succeeded_at: refund.succeeded_at, recorded_at: refund.created_at
              } },
              ticket_count: order.tickets.size, total_cents: order.total_cents, status: order.status,
              refunded_cents: order.refunded_cents, refundable_cents: order.refundable_cents, created_at: order.created_at,
              test_payment: order.test_payment?, external_refund_verification_required: verification_required
          }
        end
      end
    end
  end
end
