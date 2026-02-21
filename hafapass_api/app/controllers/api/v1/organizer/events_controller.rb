module Api
  module V1
    module Organizer
      class EventsController < ApplicationController
        include Paginatable

        before_action :require_organizer_profile
        before_action :set_event, only: [:show, :update, :destroy, :publish, :clone, :generate_recurrences, :stats, :attendees]

        def index
          events = current_organizer_profile.events.includes(:ticket_types).order(created_at: :desc)
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
          event = current_organizer_profile.events.build(event_params)
          if event.save
            render json: event_json(event), status: :created
          else
            render json: { errors: event.errors.full_messages }, status: :unprocessable_entity
          end
        end

        def update
          if @event.update(event_params)
            render json: event_json(@event)
          else
            render json: { errors: @event.errors.full_messages }, status: :unprocessable_entity
          end
        end

        def destroy
          @event.destroy
          head :no_content
        end

        def publish
          if @event.draft?
            @event.update!(status: :published, published_at: Time.current)
            render json: event_json(@event)
          else
            render json: { error: "Only draft events can be published" }, status: :unprocessable_entity
          end
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
          interval = case @event.recurrence_rule
                     when "weekly" then 1.week
                     when "biweekly" then 2.weeks
                     when "monthly" then 1.month
                     else return render json: { error: "Unsupported recurrence rule" }, status: :unprocessable_entity
                     end

          duration = @event.ends_at - @event.starts_at
          doors_offset = @event.doors_open_at ? @event.doors_open_at - @event.starts_at : nil
          generated = []

          count.times do |i|
            offset = interval * (i + 1)
            new_starts_at = @event.starts_at + offset
            new_ends_at = new_starts_at + duration
            new_doors = doors_offset ? new_starts_at + doors_offset : nil

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
          orders = @event.orders.where(status: :completed)

          total_tickets_sold = tickets.where.not(status: :cancelled).count
          total_revenue_cents = orders.sum(:total_cents)
          tickets_checked_in = tickets.where(status: :checked_in).count

          tickets_by_type = @event.ticket_types.order(:sort_order, :id).map do |tt|
            type_tickets = tickets.where(ticket_type_id: tt.id).where.not(status: :cancelled)
            {
              name: tt.name,
              sold: type_tickets.count,
              available: tt.available_quantity,
              revenue_cents: tt.price_cents * type_tickets.count
            }
          end

          recent_orders = orders.order(created_at: :desc).limit(10).map do |order|
            {
              id: order.id,
              buyer_name: order.buyer_name,
              buyer_email: order.buyer_email,
              ticket_count: order.tickets.count,
              total_cents: order.total_cents,
              created_at: order.created_at
            }
          end

          render json: {
            total_tickets_sold: total_tickets_sold,
            total_revenue_cents: total_revenue_cents,
            tickets_checked_in: tickets_checked_in,
            tickets_by_type: tickets_by_type,
            recent_orders: recent_orders
          }
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
            :category, :age_restriction, :max_capacity, :is_featured,
            :status, :recurrence_rule, :recurrence_end_date, :show_attendees
          )
        end

        def clone_event(source, overrides = {})
          attrs = source.attributes.slice(
            'title', 'description', 'short_description', 'cover_image_url',
            'venue_name', 'venue_address', 'venue_city', 'timezone',
            'category', 'age_restriction', 'max_capacity', 'is_featured',
            'show_attendees'
          ).merge(
            'organizer_profile_id' => source.organizer_profile_id,
            'status' => 'draft',
            'slug' => nil,
            'published_at' => nil
          ).merge(overrides.stringify_keys)

          new_event = Event.new(attrs)
          if new_event.save
            source.ticket_types.each do |tt|
              new_event.ticket_types.create!(
                name: tt.name,
                description: tt.description,
                price_cents: tt.price_cents,
                quantity_available: tt.quantity_available,
                quantity_sold: 0,
                max_per_order: tt.max_per_order,
                sort_order: tt.sort_order,
                sales_start_at: tt.sales_start_at,
                sales_end_at: tt.sales_end_at
              )
            end
            source.promo_codes.each do |pc|
              new_event.promo_codes.create!(
                code: pc.code,
                discount_type: pc.discount_type,
                discount_value: pc.discount_value,
                max_uses: pc.max_uses,
                current_uses: 0,
                active: pc.active,
                starts_at: pc.starts_at,
                expires_at: pc.expires_at
              )
            end
          end
          new_event
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
