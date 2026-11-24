# frozen_string_literal: true

module Api
  module V1
    module Organizer
      class BoxOfficeReceiptsController < BaseController
        before_action :set_event

        def show
          order = seller_orders.find(params[:order_id])
          render json: Commerce::BoxOfficeReceipt.new(order).as_json
        end

        def email
          address = params[:email]
          unless address.is_a?(String) && valid_address?(address = address.strip.downcase)
            return render json: { error: "Enter a valid email address." }, status: :unprocessable_entity
          end

          result = Order.transaction do
            current_organization.lock!("FOR NO KEY UPDATE")
            @event.lock!("FOR NO KEY UPDATE")
            next unless authorize_organization!(:box_office, event: @event)

            order = seller_orders.lock.find(params[:order_id])
            receipt = Commerce::BoxOfficeReceipt.new(order)
            unless receipt.fulfilled?
              raise FulfillmentResender::NotAvailable, "Tickets cannot be emailed for this order."
            end

            add_email!(order, address) unless receipt.email
            unless receipt.email.casecmp?(address)
              raise FulfillmentResender::NotAvailable, "Confirm the email address already on this order."
            end

            status = receipt.email_status
            next status if Commerce::BoxOfficeReceipt::ACTIVE_EMAIL_STATUSES.include?(status)

            delivery = FulfillmentResender.call(order: order, requested_by: current_user)
            AuditLogger.record!(action: "order.fulfillment_resent", auditable: order, actor: current_user,
              organization: current_organization, event: @event, metadata: { message_delivery_id: delivery.id },
              request: request)
            delivery.status
          end
          render json: { email: address, email_status: result }, status: :accepted if result
        rescue FulfillmentResender::NotAvailable => e
          render json: { error: e.message }, status: :unprocessable_entity
        rescue FulfillmentResender::Cooldown => e
          render json: { error: e.message }, status: :too_many_requests
        rescue FulfillmentResender::Unconfirmed => e
          render json: { error: e.message }, status: :conflict
        end

        private

        def set_event
          response.headers["Cache-Control"] = "private, no-store"
          @event = find_organization_event(params[:event_id])
          authorize_organization!(:box_office, event: @event) if @event
        end

        def seller_orders
          @event.orders.where(source: "box_office", sold_by: current_user)
        end

        def valid_address?(address)
          address.bytesize <= 254 && URI::MailTo::EMAIL_REGEXP.match?(address) && !address.end_with?("@boxoffice.local")
        end

        def add_email!(order, address)
          if order.user_id.present?
            raise FulfillmentResender::NotAvailable, "This order has already been claimed."
          end

          placeholder = order.buyer_email
          order.update!(buyer_email: address)
          # Match guest purchase recovery without changing customer-supplied
          # attendee addresses or the ownership of an accepted transfer.
          order.tickets.where(holder_user_id: nil, holder_email: placeholder).order(:id).lock.each do |ticket|
            ticket.attendee_email = address if ticket.attendee_email == placeholder
            ticket.update!(holder_email: address)
          end
        end
      end
    end
  end
end
