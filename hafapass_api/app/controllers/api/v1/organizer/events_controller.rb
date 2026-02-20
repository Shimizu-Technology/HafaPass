module Api
  module V1
    module Organizer
      class EventsController < ApplicationController
        include Paginatable

        before_action :require_organizer_profile
        before_action :set_event, only: [:show, :update, :destroy, :publish, :stats, :attendees]

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
          # NOTE: cover_image_url currently accepts a direct URL string.
          # With S3 integration, the flow would be:
          #   1. Frontend calls POST /api/v1/uploads/presign to get a presigned POST URL
          #   2. Frontend uploads the image directly to S3 using the presigned URL
          #   3. Frontend sends the resulting S3 key back here as cover_image_url
          #   4. Backend could use S3Service.generate_presigned_get(key) to serve time-limited URLs
          params.permit(
            :title, :description, :short_description, :cover_image_url,
            :venue_name, :venue_address, :venue_city,
            :starts_at, :ends_at, :doors_open_at, :timezone,
            :category, :age_restriction, :max_capacity, :is_featured,
            :status
          )
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
