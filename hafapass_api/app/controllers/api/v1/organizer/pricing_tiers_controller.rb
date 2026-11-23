module Api
  module V1
    module Organizer
      class PricingTiersController < BaseController
        before_action :set_event
        before_action :set_ticket_type
        before_action :set_pricing_tier, only: [:update, :destroy, :move]

        def index
          tiers = @ticket_type.pricing_tiers.ordered
          render json: tiers.map { |t| tier_json(t) }
        end

        def create
          tier = with_inventory_lock do
            attributes = parsed_tier_params
            attributes["position"] ||= (@ticket_type.pricing_tiers.maximum(:position) || -1) + 1
            @ticket_type.pricing_tiers.create(attributes)
          end
          if tier.persisted?
            render json: tier_json(tier), status: :created
          else
            render json: { errors: tier.errors.full_messages }, status: :unprocessable_entity
          end
        end

        def update
          updated = with_inventory_lock do
            @tier.lock!
            @tier.update(parsed_tier_params)
          end
          if updated
            render json: tier_json(@tier)
          else
            render json: { errors: @tier.errors.full_messages }, status: :unprocessable_entity
          end
        end

        def move
          direction = { "up" => -1, "down" => 1 }[params[:direction]]
          unless direction
            return render json: { error: "Choose up or down" }, status: :unprocessable_entity
          end

          moved = with_inventory_lock do
            tiers = @ticket_type.pricing_tiers.ordered.to_a
            quantity_positions = tiers.each_index.select { |index| tiers[index].quantity_based? }
            current = quantity_positions.index { |index| tiers[index].id == @tier.id }
            next false unless current && (current + direction).between?(0, quantity_positions.length - 1)

            from, to = quantity_positions.values_at(current, current + direction)
            tiers[from], tiers[to] = tiers[to], tiers[from]
            tiers.each_with_index do |tier, position|
              # A priority change should also work on legacy schedules.
              tier.update_attribute!(:position, position) unless tier.position == position
            end
            true
          end
          if moved
            head :no_content
          else
            render json: { error: "This quantity cap cannot move in that direction" }, status: :unprocessable_entity
          end
        end

        def destroy
          destroyed = with_inventory_lock do
            @tier.lock!
            @tier.destroy
          end
          if destroyed
            head :no_content
          else
            render json: { error: "Pricing tiers with inventory or financial history cannot be deleted" },
              status: :unprocessable_entity
          end
        end

        private

        def with_inventory_lock(&block)
          @event.with_lock("FOR NO KEY UPDATE") do
            @ticket_type.with_inventory_lock(&block)
          end
        end

        def set_event
          @event = find_organization_event(params[:event_id])
          authorize_organization!(:manage_inventory, event: @event) if @event
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

        def parsed_tier_params
          attributes = tier_params.to_h
          %w[starts_at ends_at].each do |key|
            attributes[key] = EventTimeParser.call(attributes[key], timezone: @event.timezone) if attributes.key?(key)
          end
          attributes
        rescue EventTimeParser::ParseError => e
          raise ActionController::BadRequest, e.message
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
            starts_at: tier.starts_at&.utc&.iso8601(6),
            ends_at: tier.ends_at&.utc&.iso8601(6),
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
