module Api
  module V1
    class EventsController < ApplicationController
      include Paginatable

      skip_before_action :authenticate_user!
      before_action :optional_authenticate!, only: [:show]

      def index
        events = Event.where(status: [:published, :completed]).includes(:ticket_types, :organizer_profile).order(starts_at: :asc)
        pagy, paginated_events = paginate(events)

        render json: {
          events: paginated_events.map { |event| event_json(event, include_ticket_types: true) },
          meta: pagination_meta(pagy)
        }
      end

      def show
        # Allow organizers to preview their own draft events
        if params[:preview] == "true" && @current_user
          event = Event.find_by!(slug: params[:slug])
          organizer_profile = @current_user.organizer_profile
          if organizer_profile && event.organizer_profile_id == organizer_profile.id
            render json: event_json(event, include_ticket_types: true)
            return
          end
        end

        event = Event.where(status: [:published, :completed]).find_by!(slug: params[:slug])
        render json: event_json(event, include_ticket_types: true)
      rescue ActiveRecord::RecordNotFound
        render json: { error: "Event not found" }, status: :not_found
      end

      private

      def optional_authenticate!
        token = extract_bearer_token
        return if token.nil?

        payload = ClerkAuthenticator.verify(token)
        return if payload.nil?

        @clerk_payload = payload
        @current_user = current_user
      end

      def anonymize_name(name)
        return "Guest" if name.blank?
        parts = name.strip.split(/\s+/)
        if parts.length > 1
          "#{parts.first} #{parts.last[0]}."
        else
          parts.first
        end
      end

      def event_json(event, include_ticket_types: false)
        completed_orders = event.orders.where(status: :completed)
        attendee_count = completed_orders.count

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
          show_attendees: event.show_attendees,
          attendee_count: attendee_count,
          attendees_preview: event.show_attendees ? completed_orders.limit(10).pluck(:buyer_name).map { |n| anonymize_name(n) } : [],
          organizer: {
            business_name: event.organizer_profile.business_name,
            logo_url: event.organizer_profile.logo_url
          },
          created_at: event.created_at,
          updated_at: event.updated_at
        }

        if include_ticket_types
          json[:ticket_types] = event.ticket_types.includes(:pricing_tiers).order(:sort_order, :id).map do |tt|
            active_tier = tt.active_pricing_tier
            next_tier = tt.next_pricing_tier
            tt_json = {
              id: tt.id,
              name: tt.name,
              description: tt.description,
              price_cents: tt.price_cents,
              current_price_cents: tt.current_price_cents,
              original_price_cents: tt.price_cents,
              quantity_available: tt.quantity_available,
              quantity_sold: tt.quantity_sold,
              max_per_order: tt.max_per_order,
              sales_start_at: tt.sales_start_at,
              sales_end_at: tt.sales_end_at
            }
            if active_tier
              tt_json[:active_tier] = {
                name: active_tier.name,
                tier_type: active_tier.tier_type,
                remaining: active_tier.quantity_based? ? (active_tier.quantity_limit - active_tier.quantity_sold) : nil,
                ends_at: active_tier.ends_at
              }
            end
            if next_tier
              tt_json[:next_tier] = {
                name: next_tier.name,
                price_cents: next_tier.price_cents
              }
            end
            tt_json
          end
        end

        json
      end
    end
  end
end
