module Api
  module V1
    module Organizer
      class EventsController < ApplicationController
        include Paginatable

        before_action :require_organizer_profile
        before_action :set_event, only: [
          :show, :update, :destroy, :publish, :postpone, :resume, :cancel, :complete, :archive,
          :clone, :generate_recurrences, :stats, :attendees
        ]

        def index
          events = current_organizer_profile.events.includes(ticket_types: :pricing_tiers).order(created_at: :desc)
          pagy, paginated_events = paginate(events)

          render json: {
            events: paginated_events.map { |event| event_json(event, include_ticket_types: true) },
            meta: pagination_meta(pagy)
          }
        end

        def show
          render json: event_json(@event, include_ticket_types: true)
        end

        def create
          event = current_organizer_profile.events.build(parsed_event_params)
          if event.save
            render json: event_json(event), status: :created
          else
            render json: { errors: event.errors.full_messages }, status: :unprocessable_entity
          end
        end

        def update
          if @event.update(parsed_event_params)
            render json: event_json(@event)
          else
            render json: { errors: @event.errors.full_messages }, status: :unprocessable_entity
          end
        end

        def destroy
          unless @event.draft?
            return render json: { error: "Only draft events can be deleted; archive or cancel this event instead" },
              status: :unprocessable_entity
          end

          if @event.destroy
            head :no_content
          else
            render json: { error: "Events with financial or ticket history cannot be deleted" }, status: :unprocessable_entity
          end
        end

        def publish
          transition_event(:publish)
        end

        def postpone
          transition_event(:postpone)
        end

        def resume
          transition_event(:resume)
        end

        def cancel
          transition_event(:cancel)
        end

        def complete
          transition_event(:complete)
        end

        def archive
          transition_event(:archive)
        end

        def clone
          cloned = clone_event(@event, title: "#{@event.title} (Copy)", starts_at: nil, ends_at: nil, doors_open_at: nil)
          if cloned.persisted?
            render json: event_json(cloned, include_ticket_types: true), status: :created
          else
            render json: { errors: cloned.errors.full_messages }, status: :unprocessable_entity
          end
        end

        def generate_recurrences
          unless @event.recurrence_rule.present?
            return render json: { error: "Event must have a recurrence rule" }, status: :unprocessable_entity
          end
          unless @event.starts_at.present? && @event.ends_at.present?
            return render json: { error: "Event must have start and end dates" }, status: :unprocessable_entity
          end

          count = [params[:count].to_i.clamp(1, 12), 1].max
          timezone = ActiveSupport::TimeZone[@event.timezone]
          local_start = @event.starts_at.in_time_zone(timezone)
          local_end = @event.ends_at.in_time_zone(timezone)
          local_doors = @event.doors_open_at&.in_time_zone(timezone)
          generated = []

          count.times do |i|
            occurrence_number = i + 1
            new_starts_at = advance_local_time(local_start, occurrence_number)
            new_ends_at = advance_local_time(local_end, occurrence_number)
            new_doors = local_doors ? advance_local_time(local_doors, occurrence_number) : nil

            break if @event.recurrence_end_date && new_starts_at.to_date > @event.recurrence_end_date

            cloned = clone_event(@event,
              starts_at: new_starts_at,
              ends_at: new_ends_at,
              doors_open_at: new_doors,
              recurrence_parent_id: @event.id,
              recurrence_rule: @event.recurrence_rule
            )
            generated << cloned if cloned.persisted?
          end

          render json: {
            generated_count: generated.size,
            events: generated.map { |e| event_json(e) }
          }, status: :created
        end

        def stats
          tickets = @event.tickets
          orders = @event.orders.where(status: [:completed, :partially_refunded, :refunded])
          financials = Commerce::LedgerTotals.call(orders)

          total_tickets_sold = tickets.where.not(status: :cancelled).count
          total_revenue_cents = financials[:net_cents]
          tickets_checked_in = tickets.where(status: :checked_in).count

          tickets_by_type = @event.ticket_types.order(:sort_order, :id).map do |tt|
            type_tickets = tickets.where(ticket_type_id: tt.id).where.not(status: :cancelled)
            {
              name: tt.name,
              sold: type_tickets.count,
              available: tt.available_quantity,
              revenue_cents: ticket_type_net_revenue(tt, orders)
            }
          end

          recent_orders = orders.order(created_at: :desc).limit(10).map do |order|
            {
              id: order.id,
              buyer_name: order.buyer_name,
              buyer_email: order.buyer_email,
              ticket_count: order.tickets.count,
              total_cents: order.total_cents,
              status: order.status,
              refunded_cents: order.refunded_cents,
              refundable_cents: order.refundable_cents,
              created_at: order.created_at
            }
          end

          render json: {
            total_tickets_sold: total_tickets_sold,
            total_revenue_cents: total_revenue_cents,
            financials: financials,
            tickets_checked_in: tickets_checked_in,
            tickets_by_type: tickets_by_type,
            recent_orders: recent_orders
          }
        end

        def ticket_type_net_revenue(ticket_type, settled_orders)
          items = OrderItem.where(order_id: settled_orders.select(:id), ticket_type_id: ticket_type.id)
          charged = items.sum(:subtotal_cents) + items.sum(:fee_cents) + items.sum(:tax_cents) - items.sum(:discount_cents)
          refunded = RefundItem.joins(:refund)
            .where(order_item_id: items.select(:id), refunds: { status: Refund.statuses[:succeeded] })
            .sum(:amount_cents)
          charged - refunded
        end

        def attendees
          tickets = @event.tickets.includes(:ticket_type, :order).order(created_at: :desc)
          pagy, paginated_tickets = paginate(tickets)

          render json: {
            attendees: paginated_tickets.map { |ticket|
              {
                id: ticket.id,
                attendee_name: ticket.attendee_name,
                attendee_email: ticket.attendee_email,
                ticket_type: ticket.ticket_type.name,
                status: ticket.status,
                checked_in_at: ticket.checked_in_at,
                qr_code: ticket.qr_code,
                order_id: ticket.order_id
              }
            },
            meta: pagination_meta(pagy)
          }
        end

        private

        def transition_event(action)
          EventLifecycle.call(event: @event, action: action, actor: current_user, reason: params[:reason])
          render json: event_json(@event.reload, include_ticket_types: true)
        rescue EventLifecycle::TransitionError => e
          render json: { error: e.message, publish_checklist: e.checklist }, status: :unprocessable_entity
        end

        def require_organizer_profile
          unless current_organizer_profile
            render json: { error: "Organizer profile required" }, status: :forbidden
          end
        end

        def current_organizer_profile
          @current_organizer_profile ||= current_user.organizer_profile
        end

        def set_event
          @event = current_organizer_profile.events.find(params[:id])
        rescue ActiveRecord::RecordNotFound
          render json: { error: "Event not found" }, status: :not_found
        end

        def event_params
          params.permit(
            :title, :description, :short_description, :cover_image_url,
            :venue_name, :venue_address, :venue_city,
            :starts_at, :ends_at, :doors_open_at, :timezone,
            :category, :age_restriction, :max_capacity,
            :recurrence_rule, :recurrence_end_date, :show_attendees
          )
        end

        def parsed_event_params
          attributes = event_params.to_h
          timezone = attributes["timezone"].presence || @event&.timezone || "Pacific/Guam"
          %w[starts_at ends_at doors_open_at].each do |key|
            attributes[key] = EventTimeParser.call(attributes[key], timezone: timezone) if attributes.key?(key)
          end
          attributes
        rescue EventTimeParser::ParseError => e
          raise ActionController::BadRequest, e.message
        end

        def clone_event(source, overrides = {})
          attrs = source.attributes.slice(
            "title", "description", "short_description", "cover_image_url",
            "venue_name", "venue_address", "venue_city", "timezone",
            "category", "age_restriction", "max_capacity",
            "show_attendees"
          ).merge(
            "organizer_profile_id" => source.organizer_profile_id,
            "status" => "draft",
            "slug" => nil,
            "published_at" => nil
          ).merge(overrides.stringify_keys)

          new_event = Event.new(attrs)
          if new_event.save
            source.ticket_types.each do |tt|
              cloned_ticket_type = new_event.ticket_types.create!(
                name: tt.name,
                description: tt.description,
                price_cents: tt.price_cents,
                quantity_available: tt.quantity_available,
                quantity_sold: 0,
                max_per_order: tt.max_per_order,
                sort_order: tt.sort_order,
                sales_start_at: shifted_relative_time(tt.sales_start_at, source, new_event),
                sales_end_at: shifted_relative_time(tt.sales_end_at, source, new_event)
              )
              tt.pricing_tiers.each do |tier|
                cloned_ticket_type.pricing_tiers.create!(
                  name: tier.name,
                  price_cents: tier.price_cents,
                  tier_type: tier.tier_type,
                  quantity_limit: tier.quantity_limit,
                  quantity_sold: 0,
                  starts_at: shifted_relative_time(tier.starts_at, source, new_event),
                  ends_at: shifted_relative_time(tier.ends_at, source, new_event),
                  position: tier.position
                )
              end
            end
            source.promo_codes.each do |promo|
              new_event.promo_codes.create!(
                code: promo.code,
                discount_type: promo.discount_type,
                discount_value: promo.discount_value,
                max_uses: promo.max_uses,
                current_uses: 0,
                active: false,
                starts_at: shifted_relative_time(promo.starts_at, source, new_event),
                expires_at: shifted_relative_time(promo.expires_at, source, new_event)
              )
            end
          end
          new_event
        end

        def shifted_relative_time(value, source, destination)
          return if value.blank? || source.starts_at.blank? || destination.starts_at.blank?

          destination.starts_at + (value - source.starts_at)
        end

        def advance_local_time(value, occurrence_number)
          case @event.recurrence_rule
          when "weekly" then value.advance(weeks: occurrence_number)
          when "biweekly" then value.advance(weeks: occurrence_number * 2)
          when "monthly" then value.advance(months: occurrence_number)
          else raise ActionController::BadRequest, "Unsupported recurrence rule"
          end
        end

        def event_json(event, include_ticket_types: false)
          json = {
            id: event.id,
            title: event.title,
            slug: event.slug,
            description: event.description,
            short_description: event.short_description,
            cover_image_url: event.cover_image_url,
            venue_name: event.venue_name,
            venue_address: event.venue_address,
            venue_city: event.venue_city,
            starts_at: event.starts_at,
            ends_at: event.ends_at,
            doors_open_at: event.doors_open_at,
            timezone: event.timezone,
            status: event.status,
            category: event.category,
            category_label: event.category_label,
            age_restriction: event.age_restriction,
            max_capacity: event.max_capacity,
            is_featured: event.is_featured,
            published_at: event.published_at,
            recurrence_rule: event.recurrence_rule,
            recurrence_parent_id: event.recurrence_parent_id,
            recurrence_end_date: event.recurrence_end_date,
            show_attendees: event.show_attendees,
            created_at: event.created_at,
            updated_at: event.updated_at
          }

          json[:publish_checklist] = event.publish_checklist
          json[:state_history] = event.event_state_changes.order(occurred_at: :desc).limit(20).map do |change|
            {
              action: change.action,
              from_status: change.from_status,
              to_status: change.to_status,
              reason: change.reason,
              occurred_at: change.occurred_at
            }
          end

          if include_ticket_types
            json[:ticket_types] = event.ticket_types.order(:sort_order, :id).map do |tt|
              {
                id: tt.id,
                name: tt.name,
                description: tt.description,
                price_cents: tt.price_cents,
                quantity_available: tt.quantity_available,
                quantity_sold: tt.quantity_sold,
                max_per_order: tt.max_per_order,
                sales_start_at: tt.sales_start_at,
                sales_end_at: tt.sales_end_at
              }
            end
          end

          json
        end
      end
    end
  end
end
