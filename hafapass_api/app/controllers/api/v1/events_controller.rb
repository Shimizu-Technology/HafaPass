module Api
  module V1
    class EventsController < ApplicationController
      include Paginatable

      skip_before_action :authenticate_user!
      before_action :optional_authenticate!, only: [:show]

      def index
        events = filtered_events.includes(ticket_types: :pricing_tiers).includes(:organizer_profile).order(starts_at: :asc)
        pagy, paginated_events = paginate(events)

        render json: {
          events: paginated_events.map { |event| event_json(event, include_ticket_types: true) },
          meta: pagination_meta(pagy)
        }
      end

      def categories
        render json: {
          categories: Event::CATEGORY_LABELS.map { |value, label| { value: value, label: label } }
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

        event = Event.publicly_visible.find_by!(slug: params[:slug])
        render json: event_json(event, include_ticket_types: true)
      rescue ActiveRecord::RecordNotFound
        render json: { error: "Event not found" }, status: :not_found
      end

      private

      def filtered_events
        events = Event.discoverable
        if params[:q].present?
          query = "%#{ActiveRecord::Base.sanitize_sql_like(params[:q].to_s.strip)}%"
          events = events.where(<<~SQL.squish, query: query)
            events.title ILIKE :query OR events.description ILIKE :query OR
            events.short_description ILIKE :query OR events.venue_name ILIKE :query OR events.venue_city ILIKE :query
          SQL
        end
        events = events.where(category: params[:category]) if Event.categories.key?(params[:category].to_s)
        events = events.where(is_featured: true) if ActiveModel::Type::Boolean.new.cast(params[:featured])
        events = events.where(starts_at: parse_date_boundary(params[:date_from], beginning: true)..) if params[:date_from].present?
        events = events.where(starts_at: ..parse_date_boundary(params[:date_to], beginning: false)) if params[:date_to].present?
        events
      end

      def parse_date_boundary(value, beginning:)
        date = Date.iso8601(value.to_s)
        local = beginning ? date.beginning_of_day : date.end_of_day
        ActiveSupport::TimeZone["Pacific/Guam"].local(local.year, local.month, local.day, local.hour, local.min, local.sec)
      rescue Date::Error
        raise ActionController::BadRequest, "Invalid date filter"
      end

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
        content = event.content_for(params[:locale].presence || request.headers["Accept-Language"])
        active_tickets = event.tickets.where.not(status: :cancelled)
        attendee_count = active_tickets.count

        json = {
          id: event.id,
          title: content[:title],
          slug: event.slug,
          description: content[:description],
          short_description: content[:short_description],
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
          show_attendees: event.show_attendees,
          attendee_count: attendee_count,
          fee_policy: event.fee_policy,
          buyer_fee_percent: event.buyer_fee_percent,
          transfers_enabled: event.transfers_enabled,
          supported_locales: event.supported_locales,
          localized_content: event.localized_content,
          catalog_items: event.catalog_items.available.map { |item| catalog_item_json(item) },
          registration_questions: event.registration_questions.published.map { |question| registration_question_json(question) },
          waivers: event.event_waivers.published.map { |waiver| waiver_json(waiver) },
          attendees_preview: event.show_attendees ? active_tickets.limit(10).pluck(:attendee_name).map { |name| anonymize_name(name) } : [],
          purchasable: event.sales_open? && event.has_available_inventory?,
          organizer: {
            business_name: event.organizer_profile.business_name,
            logo_url: event.organizer_profile.logo_url,
            verified: event.organizer_profile.verification_status_verified?
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
              quantity_remaining: tt.available_quantity,
              on_sale: event.sales_open? && tt.on_sale?,
              max_per_order: tt.max_per_order,
              max_per_buyer: tt.max_per_buyer,
              sales_start_at: tt.sales_start_at,
              sales_end_at: tt.sales_end_at
            }
            if active_tier
              tt_json[:active_tier] = {
                name: active_tier.name,
                tier_type: active_tier.tier_type,
                remaining: active_tier.quantity_based? ? [active_tier.quantity_limit - active_tier.quantity_sold - active_tier.inventory_holds.current.sum(:quantity), 0].max : nil,
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

      def catalog_item_json(item)
        {
          id: item.id, name: item.name, description: item.description, kind: item.kind,
          price_cents: item.price_cents, minimum_price_cents: item.minimum_price_cents,
          maximum_price_cents: item.maximum_price_cents,
          quantity_remaining: item.inventory_quantity ? item.available_quantity : nil
        }
      end

      def registration_question_json(question)
        { id: question.id, prompt: question.prompt, kind: question.kind, required: question.required, options: question.options }
      end

      def waiver_json(waiver)
        { id: waiver.id, title: waiver.title, body: waiver.body, version: waiver.version, required: waiver.required }
      end
    end
  end
end
