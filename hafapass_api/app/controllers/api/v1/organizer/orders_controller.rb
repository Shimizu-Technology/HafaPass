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
          render json: {
            orders: records.map { |order| order_json(order) },
            meta: pagination_meta(pagy)
          }
        end

        private

        def order_json(order)
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
              test_payment: order.test_payment?
          }
        end
      end
    end
  end
end
