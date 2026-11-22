module Api
  module V1
    module Organizer
      class TicketTypesController < BaseController
        before_action :set_event
        before_action :set_ticket_type, only: [:show, :update, :destroy, :sync_pass_holders]

        def index
          ticket_types = @event.ticket_types.includes(:pricing_tiers, ticket_type_included_events: :included_event).order(:sort_order, :id)
          render json: ticket_types.map { |tt| ticket_type_json(tt) }
        end

        def show
          render json: ticket_type_json(@ticket_type)
        end

        def create
          ticket_type = @event.ticket_types.build(parsed_ticket_type_params)
          included_ids_param = params.key?(:included_event_ids) ? params[:included_event_ids] : nil
          saved = false
          forbidden = false
          Event.transaction do
            included_events = resolve_included_events(ticket_type, included_ids_param)
            if ticket_type.errors.any?
              raise ActiveRecord::Rollback
            end
            unless authorized_for_included_events?(included_events)
              forbidden = true
              raise ActiveRecord::Rollback
            end

            Passes::Locking.lock_events!([@event, *included_events])
            if ticket_type.save && sync_included_events!(ticket_type, included_events, included_ids_param)
              saved = true
            else
              raise ActiveRecord::Rollback
            end
          end
          if forbidden
            render json: { error: "You do not have permission to perform this action" }, status: :forbidden
          elsif saved
            ticket_type.reload
            render json: ticket_type_json(ticket_type), status: :created
          else
            render json: { errors: ticket_type.errors.full_messages }, status: :unprocessable_entity
          end
        end

        def update
          included_ids_param = params.key?(:included_event_ids) ? params[:included_event_ids] : nil
          updated = false
          forbidden = false
          Passes::Locking.with_lock_retry do
            @ticket_type.errors.clear
            updated = false
            forbidden = false
            Event.transaction do
              included_events = resolve_included_events(@ticket_type, included_ids_param)
              if @ticket_type.errors.any?
                raise ActiveRecord::Rollback
              end

              existing_included = @ticket_type.included_events.to_a
              locked_events = Passes::Locking.lock_events!([@event, *existing_included, *included_events])
              locked_event_ids = locked_events.map(&:id)
              current_existing_ids = @ticket_type.ticket_type_included_events.pluck(:included_event_id)
              if (current_existing_ids - locked_event_ids).any?
                raise Passes::Locking::LockSetChanged, "Included events changed while acquiring event locks"
              end

              @ticket_type.lock!
              if !included_ids_param.nil?
                existing_events = current_existing_ids.any? ? Event.where(id: current_existing_ids).to_a : []
                unless authorized_for_included_events?(included_events + existing_events)
                  forbidden = true
                  raise ActiveRecord::Rollback
                end
              end

              if @ticket_type.update(parsed_ticket_type_params) &&
                  sync_included_events!(@ticket_type, included_events, included_ids_param)
                updated = true
              else
                raise ActiveRecord::Rollback
              end
            end
          end
          if forbidden
            render json: { error: "You do not have permission to perform this action" }, status: :forbidden
          elsif updated
            @ticket_type.reload
            render json: ticket_type_json(@ticket_type)
          else
            render json: { errors: @ticket_type.errors.full_messages }, status: :unprocessable_entity
          end
        end

        def destroy
          destroyed = @event.with_lock("FOR NO KEY UPDATE") do
            @ticket_type.lock!
            @ticket_type.destroy
          end
          if destroyed
            head :no_content
          else
            render json: { error: "Ticket types with inventory or financial history cannot be deleted" },
              status: :unprocessable_entity
          end
        end

        def sync_pass_holders
          unless authorized_for_included_events?(@ticket_type.included_events.to_a)
            return render json: { error: "You do not have permission to perform this action" }, status: :forbidden
          end

          result = Passes::SyncPassHolders.call(ticket_type: @ticket_type, actor: current_user, request: request)
          render json: {
            ticket_type_id: result.ticket_type.id,
            parent_ticket_count: result.parent_ticket_count,
            issued_ticket_count: result.issued_ticket_count,
            included_event_ids: result.included_event_ids
          }, status: :ok
        rescue Passes::SyncPassHolders::AuthorizationError => e
          render json: { error: e.message }, status: :forbidden
        rescue Passes::SyncPassHolders::SyncError => e
          render json: { error: e.message }, status: :unprocessable_entity
        end

        private

        def set_event
          @event = find_organization_event(params[:event_id])
          return unless @event

          if action_name == "sync_pass_holders"
            allowed = %i[manage_inventory manage_events].any? do |permission|
              OrganizationAuthorization.allowed?(user: current_user, organization: current_organization,
                permission: permission, event: @event)
            end
            render json: { error: "You do not have permission to perform this action" }, status: :forbidden unless allowed
          else
            authorize_organization!(:manage_inventory, event: @event)
          end
        end

        def resolve_included_events(ticket_type, included_ids_param)
          return [] if included_ids_param.nil?

          unless included_ids_param.is_a?(Array)
            ticket_type.errors.add(:base, "included_event_ids must be an array")
            return []
          end

          parsed_ids = included_ids_param.map { |value| Integer(value, exception: false) }
          if parsed_ids.any? { |value| value.nil? || !value.positive? }
            ticket_type.errors.add(:base, "Included event IDs must be valid event IDs")
            return []
          end

          unique_ids = parsed_ids.uniq
          events_by_id = current_organization.events.where(id: unique_ids).index_by(&:id)
          if events_by_id.size != unique_ids.size
            ticket_type.errors.add(:base, "Included events must belong to this organization")
            return []
          end

          unique_ids.map { |id| events_by_id.fetch(id) }
        end

        def authorized_for_included_events?(events)
          Array(events).compact.uniq(&:id).all? do |included_event|
            OrganizationAuthorization.allowed?(
              user: current_user,
              organization: current_organization,
              permission: :manage_inventory,
              event: included_event
            )
          end
        end

        def sync_included_events!(ticket_type, included_events, included_ids_param)
          return true if included_ids_param.nil?

          desired_ids = included_events.map(&:id)
          existing_links = ticket_type.ticket_type_included_events.reload.to_a
          existing_by_event_id = existing_links.index_by(&:included_event_id)
          added_ids = desired_ids - existing_by_event_id.keys

          if added_ids.any?
            if !ticket_type.is_pass? &&
                (ticket_type.quantity_sold.positive? || ticket_type.tickets.exists? || ticket_type.inventory_holds.active.exists?)
              ticket_type.errors.add(:base, "A ticket type with existing sales or active holds cannot be converted into a multi-night pass")
              return false
            end
            if ticket_type.inventory_holds.active.exists?
              ticket_type.errors.add(:base, "Included events cannot be added while pass checkouts are in progress")
              return false
            end
          end

          removed_links = existing_links.reject { |link| desired_ids.include?(link.included_event_id) }
          removed_links.each do |link|
            next if link.destroy

            link.errors.full_messages.each { |msg| ticket_type.errors.add(:base, msg) }
            return false
          end

          desired_ids.each_with_index do |event_id, position|
            if (existing = existing_by_event_id[event_id])
              next if existing.position == position
              next if existing.update(position: position)

              existing.errors.full_messages.each { |msg| ticket_type.errors.add(:base, msg) }
              return false
            else
              link = ticket_type.ticket_type_included_events.build(included_event_id: event_id, position: position)
              next if link.save

              link.errors.full_messages.each { |msg| ticket_type.errors.add(:base, msg) }
              return false
            end
          end

          should_be_pass = desired_ids.any?
          ticket_type.update_column(:is_pass, should_be_pass) if ticket_type.is_pass? != should_be_pass
          true
        end

        def set_ticket_type
          @ticket_type = @event.ticket_types.find(params[:id])
        rescue ActiveRecord::RecordNotFound
          render json: { error: "Ticket type not found" }, status: :not_found
        end

        def ticket_type_params
          params.permit(
            :name, :description, :price_cents, :quantity_available,
            :max_per_order, :max_per_buyer, :door_allocation, :sales_start_at, :sales_end_at, :sort_order,
            :attendee_info_mode
          )
        end

        def parsed_ticket_type_params
          attributes = ticket_type_params.to_h
          %w[sales_start_at sales_end_at].each do |key|
            attributes[key] = EventTimeParser.call(attributes[key], timezone: @event.timezone) if attributes.key?(key)
          end
          attributes
        rescue EventTimeParser::ParseError => e
          raise ActionController::BadRequest, e.message
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
            door_allocation: tt.door_allocation,
            door_sold_quantity: tt.door_sold_quantity,
            door_held_quantity: tt.door_held_quantity,
            door_available_quantity: tt.door_available_quantity,
            sold_out: tt.sold_out?,
            max_per_order: tt.max_per_order,
            max_per_buyer: tt.max_per_buyer,
            attendee_info_mode: tt.attendee_info_mode,
            sales_start_at: tt.sales_start_at,
            sales_end_at: tt.sales_end_at,
            sort_order: tt.sort_order,
            is_pass: tt.is_pass?,
            included_event_ids: tt.ticket_type_included_events.map(&:included_event_id),
            included_events: tt.ticket_type_included_events.includes(:included_event).filter_map { |link|
              link.included_event && Passes::TicketPayload.included_event_json(link.included_event)
            },
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
