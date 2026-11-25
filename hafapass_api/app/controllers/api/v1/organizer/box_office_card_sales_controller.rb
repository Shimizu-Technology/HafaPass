# frozen_string_literal: true

module Api
  module V1
    module Organizer
      class BoxOfficeCardSalesController < BaseController
        before_action :set_event
        rescue_from Commerce::OnlineDoorSale::Unavailable, with: :render_unavailable
        rescue_from Commerce::OnlineDoorSale::ProviderUnknown, with: :render_uncertain

        def index
          orders = accessible_orders
          pending = orders.pending.where("expires_at > ?", Time.current).order(id: :desc).limit(20)
          paid = orders.where(status: [:completed, :partially_refunded], completed_at: 24.hours.ago..)
            .order(completed_at: :desc, id: :desc).limit(10)
          render json: { orders: (pending.to_a + paid.to_a).map { |order|
            order.as_json(only: [:id, :reference, :buyer_name, :payment_method, :total_cents])
              .merge(status: order.pending? ? "waiting" : "paid")
          } }
        end

        def create
          order = Commerce::OnlineDoorSale.call(event: @event, user: current_user,
            parameters: params.permit(:payment_method, :buyer_name, :buyer_email, :buyer_phone, :seat_hold_token, :expected_total_cents,
              line_items: [:ticket_type_id, :quantity], registration_answers: {}),
            idempotency_key: request.headers["Idempotency-Key"])
          render json: sale_json(order)
        rescue Commerce::OnlineDoorSale::AlreadyPaid => e
          render json: sale_json(e.order.reload, provider_paid: true)
        rescue Commerce::OrderCreator::PriceChanged => e
          render json: { error: e.message, code: "price_changed", reconciliation_required: false }, status: :conflict
        rescue CheckoutAttempt::Conflict => e
          render json: { error: e.message, reconciliation_required: e.recovery_required }, status: :conflict
        rescue Commerce::OrderCreator::CheckoutError => e
          render json: { error: e.message, reconciliation_required: false }, status: :unprocessable_content
        rescue StripeService::PaymentError
          render_unavailable(Commerce::OnlineDoorSale::Unavailable.new("Stripe payments are unavailable."))
        end

        def show
          order = accessible_order
          check_provider = params[:check_provider] == "1"
          provider_paid = check_provider && Commerce::OnlineDoorSale.provider_paid?(order)
          render json: sale_json(check_provider ? order.reload : order, provider_paid: provider_paid, checked: check_provider)
        end

        def destroy
          render json: sale_json(Commerce::OnlineDoorSale.cancel!(accessible_order))
        end

        def email
          delivery = Order.transaction do
            current_organization.lock!("FOR NO KEY UPDATE")
            @event.lock!("FOR NO KEY UPDATE")
            next unless authorize_organization!(:box_office, event: @event)

            order = accessible_order(lock: true)
            if order.completed? || order.partially_refunded?
              unless tickets_available?(order) && Commerce::OnlineDoorSale.buyer_email(order)
                raise Commerce::OnlineDoorSale::Unavailable, "Tickets or a buyer email are unavailable."
              end
              next FulfillmentResender.call(order: order, requested_by: current_user)
            end

            unless order.payment_method == "door_card_link" && Commerce::OnlineDoorSale.link_available?(order) &&
                Commerce::OnlineDoorSale.buyer_email(order)
              raise Commerce::OnlineDoorSale::Unavailable, "The buyer email or an active payment link is missing."
            end
            order.message_deliveries.find_by(template: "door_payment_link") ||
              EmailService.send_door_payment_link_async(order, requested_by: current_user)
          end
          if delivery
            key = delivery.template == "fulfillment_resend" ? :ticket_email_status : :link_email_status
            render json: { key => delivery.status }, status: :accepted
          end
        rescue FulfillmentResender::Unconfirmed, FulfillmentResender::Cooldown => e
          render json: { error: e.message }, status: :conflict
        rescue FulfillmentResender::NotAvailable => e
          render_unavailable(e)
        end

        private

        def set_event
          response.headers["Cache-Control"] = "private, no-store"
          @event = find_organization_event(params[:event_id])
          authorize_organization!(:box_office, event: @event) if @event
        end

        def accessible_orders
          orders = @event.orders.where(source: "box_office", payment_method: Order::ONLINE_DOOR_CARD_METHODS)
          return orders if OrganizationAuthorization.allowed?(user: current_user, organization: current_organization,
            permission: :manage_staff, event: @event)

          orders.where(sold_by: current_user)
        end

        def accessible_order(lock: false)
          orders = accessible_orders
          orders = orders.lock if lock
          orders.find(params[:id])
        end

        def tickets_available?(order)
          order.ticket_fulfilled? && !order.ticket_access_blocked? && !order.full_refund_pending?
        end

        def sale_json(order, provider_paid: false, checked: false)
          payment = order.payments.sole
          state = sale_state(order, payment)
          state = "confirming" if provider_paid && %w[waiting failed expired].include?(state)
          paid = state == "paid" && tickets_available?(order)
          {
            id: order.id,
            reference: order.reference,
            status: state,
            payment_method: order.payment_method,
            total_cents: order.total_cents,
            expires_at: order.expires_at,
            checkout_url: %w[waiting failed].include?(state) && order.pending? ? payment.stripe_checkout_url : nil,
            pending: state != "confirming" && order.pending? && order.expires_at&.future?,
            payment_checked: checked,
            can_retry_setup: state == "waiting" && @event.online_door_card_enabled? && payment.stripe_checkout_session_id.nil?,
            can_email_tickets: paid && Commerce::OnlineDoorSale.buyer_email(order).present?,
            can_email_link: order.payment_method == "door_card_link" && Commerce::OnlineDoorSale.buyer_email(order).present?,
            link_email_status: order.message_deliveries.find_by(template: "door_payment_link")&.status,
            tickets: paid ? ticket_json(order) : []
          }
        end

        def sale_state(order, payment)
          return "paid" if order.completed? || order.partially_refunded?
          return "refunded" if order.refunded? || payment.refunded?
          return "refunding" if payment.succeeded? && Commerce::LateCaptureRefund.open_issue?(payment)
          return "expired" if order.expired? || (order.pending? && !order.expires_at&.future?)
          return "failed" if payment.failed? || (order.pending? && payment.provider_payload.to_h["status"] == "requires_payment_method")
          return "cancelled" if order.cancelled?

          "waiting"
        end

        def ticket_json(order)
          order.tickets.scannable.includes(:event, :ticket_type, :parent_ticket).order(:id).filter_map do |ticket|
            next unless ticket.admission_allowed? && !ticket.transferred_away_from?(order) &&
              !ticket.parent_ticket&.transferred_away_from?(order)

            { id: ticket.id, scan_credential: ticket.scan_credential, tier: ticket.ticket_type.name,
              event: ticket.event.title }
          end
        end

        def render_unavailable(error)
          render json: { error: error.message, reconciliation_required: false }, status: :unprocessable_content
        end

        def render_uncertain(error)
          render json: { error: error.message, reconciliation_required: true, order_id: error.order_id }, status: :bad_gateway
        end
      end
    end
  end
end
