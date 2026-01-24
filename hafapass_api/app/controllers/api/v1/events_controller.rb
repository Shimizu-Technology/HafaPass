module Api
  module V1
    class EventsController < ApplicationController
      skip_before_action :authenticate_user!

      def index
        events = Event.published.upcoming.includes(:ticket_types, :organizer_profile).order(starts_at: :asc)
        render json: events.map { |event| event_json(event, include_ticket_types: true) }
      end

      def show
        event = Event.published.find_by!(slug: params[:slug])
        render json: event_json(event, include_ticket_types: true)
      rescue ActiveRecord::RecordNotFound
        render json: { error: "Event not found" }, status: :not_found
      end

      private

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
          organizer: {
            business_name: event.organizer_profile.business_name,
            logo_url: event.organizer_profile.logo_url
          },
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
