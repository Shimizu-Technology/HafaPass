module Api
  module V1
    module Organizer
      class TicketTypesController < ApplicationController
        before_action :require_organizer_profile
        before_action :set_event
        before_action :set_ticket_type, only: [:show, :update, :destroy]

        def index
          ticket_types = @event.ticket_types.order(:sort_order, :id)
          render json: ticket_types.map { |tt| ticket_type_json(tt) }
        end

        def show
          render json: ticket_type_json(@ticket_type)
        end

        def create
          ticket_type = @event.ticket_types.build(ticket_type_params)
          if ticket_type.save
            render json: ticket_type_json(ticket_type), status: :created
          else
            render json: { errors: ticket_type.errors.full_messages }, status: :unprocessable_entity
          end
        end

        def update
          if @ticket_type.update(ticket_type_params)
            render json: ticket_type_json(@ticket_type)
          else
            render json: { errors: @ticket_type.errors.full_messages }, status: :unprocessable_entity
          end
        end

        def destroy
          if @ticket_type.quantity_sold > 0
            render json: { error: "Cannot delete a ticket type that has sold tickets" }, status: :unprocessable_entity
          else
            @ticket_type.destroy
            head :no_content
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

        def set_ticket_type
          @ticket_type = @event.ticket_types.find(params[:id])
        rescue ActiveRecord::RecordNotFound
          render json: { error: "Ticket type not found" }, status: :not_found
        end

        def ticket_type_params
          params.permit(
            :name, :description, :price_cents, :quantity_available,
            :max_per_order, :sales_start_at, :sales_end_at, :sort_order
          )
        end

        def ticket_type_json(tt)
          {
            id: tt.id,
            event_id: tt.event_id,
            name: tt.name,
            description: tt.description,
            price_cents: tt.price_cents,
            current_price_cents: tt.current_price_cents,
            quantity_available: tt.quantity_available,
            quantity_sold: tt.quantity_sold,
            available_quantity: tt.available_quantity,
            sold_out: tt.sold_out?,
            max_per_order: tt.max_per_order,
            sales_start_at: tt.sales_start_at,
            sales_end_at: tt.sales_end_at,
            sort_order: tt.sort_order,
            pricing_tiers: tt.pricing_tiers.ordered.map { |t|
              {
                id: t.id,
                name: t.name,
                price_cents: t.price_cents,
                tier_type: t.tier_type,
                quantity_limit: t.quantity_limit,
                quantity_sold: t.quantity_sold,
                starts_at: t.starts_at,
                ends_at: t.ends_at,
                position: t.position,
                active: t.active?
              }
            },
            created_at: tt.created_at,
            updated_at: tt.updated_at
          }
        end
      end
    end
  end
end
