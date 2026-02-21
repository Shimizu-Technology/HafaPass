module Api
  module V1
    module Organizer
      class PricingTiersController < ApplicationController
        before_action :require_organizer_profile
        before_action :set_event
        before_action :set_ticket_type
        before_action :set_pricing_tier, only: [:update, :destroy]

        def index
          tiers = @ticket_type.pricing_tiers.ordered
          render json: tiers.map { |t| tier_json(t) }
        end

        def create
          tier = @ticket_type.pricing_tiers.build(tier_params)
          if tier.save
            render json: tier_json(tier), status: :created
          else
            render json: { errors: tier.errors.full_messages }, status: :unprocessable_entity
          end
        end

        def update
          if @tier.update(tier_params)
            render json: tier_json(@tier)
          else
            render json: { errors: @tier.errors.full_messages }, status: :unprocessable_entity
          end
        end

        def destroy
          @tier.destroy
          head :no_content
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
          @ticket_type = @event.ticket_types.find(params[:ticket_type_id])
        rescue ActiveRecord::RecordNotFound
          render json: { error: "Ticket type not found" }, status: :not_found
        end

        def set_pricing_tier
          @tier = @ticket_type.pricing_tiers.find(params[:id])
        rescue ActiveRecord::RecordNotFound
          render json: { error: "Pricing tier not found" }, status: :not_found
        end

        def tier_params
          params.permit(:name, :price_cents, :tier_type, :quantity_limit, :starts_at, :ends_at, :position)
        end

        def tier_json(tier)
          {
            id: tier.id,
            ticket_type_id: tier.ticket_type_id,
            name: tier.name,
            price_cents: tier.price_cents,
            tier_type: tier.tier_type,
            quantity_limit: tier.quantity_limit,
            quantity_sold: tier.quantity_sold,
            starts_at: tier.starts_at,
            ends_at: tier.ends_at,
            position: tier.position,
            active: tier.active?,
            created_at: tier.created_at,
            updated_at: tier.updated_at
          }
        end
      end
    end
  end
end
