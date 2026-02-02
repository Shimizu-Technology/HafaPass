module Api
  module V1
    module Organizer
      class GuestListEntriesController < ApplicationController
        before_action :require_organizer_profile
        before_action :set_event
        before_action :set_entry, only: [:show, :update, :destroy, :redeem]

        # GET /api/v1/organizer/events/:event_id/guest_list
        def index
          entries = @event.guest_list_entries
            .includes(:ticket_type, :order)
            .order(created_at: :desc)
          render json: entries.map { |e| entry_json(e) }
        end

        # POST /api/v1/organizer/events/:event_id/guest_list
        def create
          entry = @event.guest_list_entries.build(entry_params)
          entry.added_by = @current_user.email

          if entry.save
            # Send notification email if guest has email
            begin
              EmailService.send_guest_list_notification(entry)
            rescue => e
              Rails.logger.error("Failed to send guest list notification: #{e.message}")
            end

            render json: entry_json(entry), status: :created
          else
            render json: { errors: entry.errors.full_messages }, status: :unprocessable_entity
          end
        end

        # PATCH /api/v1/organizer/events/:event_id/guest_list/:id
        def update
          if @entry.update(entry_params)
            render json: entry_json(@entry)
          else
            render json: { errors: @entry.errors.full_messages }, status: :unprocessable_entity
          end
        end

        # DELETE /api/v1/organizer/events/:event_id/guest_list/:id
        def destroy
          if @entry.redeemed?
            render json: { error: "Cannot delete a redeemed guest list entry" }, status: :unprocessable_entity
            return
          end
          @entry.destroy
          head :no_content
        end

        # POST /api/v1/organizer/events/:event_id/guest_list/:id/redeem
        # Converts guest list entry into actual tickets
        def redeem
          ActiveRecord::Base.transaction do
            # Lock the entry to prevent concurrent redemption
            @entry.lock!

            # Check redemption status after acquiring lock
            if @entry.redeemed?
              render json: { error: "Already redeemed" }, status: :unprocessable_entity
              return
            end

            # Lock the ticket type row to prevent race conditions on availability
            ticket_type = @entry.ticket_type.lock!

            if @entry.quantity > ticket_type.available_quantity
              render json: { error: "Not enough tickets available" }, status: :unprocessable_entity
              return
            end

            # Create a comp order (zero-cost)
            order = Order.create!(
              event: @event,
              status: :completed,
              subtotal_cents: 0,
              service_fee_cents: 0,
              discount_cents: 0,
              total_cents: 0,
              buyer_email: @entry.guest_email || "guest@hafapass.com",
              buyer_name: @entry.guest_name,
              buyer_phone: @entry.guest_phone,
              completed_at: Time.current
            )

            @entry.quantity.times do
              order.tickets.create!(
                ticket_type: ticket_type,
                event: @event,
                attendee_name: @entry.guest_name,
                attendee_email: @entry.guest_email
              )
            end

            ticket_type.increment!(:quantity_sold, @entry.quantity)
            @entry.redeem!(order)
          end

          # Send ticket emails
          begin
            EmailService.send_order_confirmation(@entry.order)
          rescue => e
            Rails.logger.error("Failed to send comp ticket email: #{e.message}")
          end

          render json: entry_json(@entry.reload)
        end

        private

        def require_organizer_profile
          unless current_organizer_profile
            render json: { error: "Organizer profile required" }, status: :forbidden
            return
          end
        end

        def current_organizer_profile
          @current_organizer_profile ||= current_user.organizer_profile
        end

        def set_event
          return if performed?
          @event = current_organizer_profile.events.find(params[:event_id])
        rescue ActiveRecord::RecordNotFound
          render json: { error: "Event not found" }, status: :not_found
        end

        def set_entry
          @entry = @event.guest_list_entries.find(params[:id])
        rescue ActiveRecord::RecordNotFound
          render json: { error: "Entry not found" }, status: :not_found
        end

        def entry_params
          params.permit(:guest_name, :guest_email, :guest_phone, :notes, :quantity, :ticket_type_id)
        end

        def entry_json(entry)
          {
            id: entry.id,
            guest_name: entry.guest_name,
            guest_email: entry.guest_email,
            guest_phone: entry.guest_phone,
            notes: entry.notes,
            quantity: entry.quantity,
            redeemed: entry.redeemed,
            ticket_type: {
              id: entry.ticket_type.id,
              name: entry.ticket_type.name
            },
            order_id: entry.order_id,
            added_by: entry.added_by,
            created_at: entry.created_at
          }
        end
      end
    end
  end
end
