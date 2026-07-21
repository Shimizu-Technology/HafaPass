module Api
  module V1
    class EventsController < ApplicationController
      include Paginatable

      EFFECTIVE_TICKET_PRICE_SQL = <<~SQL.squish.freeze
        COALESCE((
          SELECT pricing_tiers.price_cents
          FROM pricing_tiers
          WHERE pricing_tiers.ticket_type_id = ticket_types.id
            AND (
              (pricing_tiers.tier_type = 0
                AND (pricing_tiers.starts_at IS NOT NULL OR pricing_tiers.ends_at IS NOT NULL)
                AND (pricing_tiers.starts_at IS NULL OR pricing_tiers.starts_at <= :price_at)
                AND (pricing_tiers.ends_at IS NULL OR pricing_tiers.ends_at >= :price_at))
              OR
              (pricing_tiers.tier_type = 1
                AND pricing_tiers.quantity_sold + COALESCE((
                  SELECT SUM(tier_holds.quantity) FROM inventory_holds tier_holds
                  WHERE tier_holds.pricing_tier_id = pricing_tiers.id
                    AND tier_holds.status = 0 AND tier_holds.expires_at > :price_at
                ), 0) + COALESCE((
                  SELECT SUM(tier_offers.quantity) FROM waitlist_offers tier_offers
                  WHERE tier_offers.pricing_tier_id = pricing_tiers.id
                    AND tier_offers.status = 0 AND tier_offers.expires_at > :price_at
                ), 0) + COALESCE((
                  SELECT COUNT(*)
                  FROM seat_holds tier_seat_holds
                  INNER JOIN seat_hold_sessions tier_seat_sessions
                    ON tier_seat_sessions.id = tier_seat_holds.seat_hold_session_id
                  WHERE tier_seat_holds.pricing_tier_id = pricing_tiers.id
                    AND tier_seat_holds.status = 0
                    AND tier_seat_sessions.status = 0
                    AND tier_seat_sessions.expires_at > :price_at
                ), 0) < pricing_tiers.quantity_limit)
            )
          ORDER BY pricing_tiers.position ASC, pricing_tiers.id ASC
          LIMIT 1
        ), ticket_types.price_cents)
      SQL

      skip_before_action :authenticate_user!
      before_action :optional_authenticate!, only: [:index, :show]

      def index
        events = filtered_events.includes(
          :organizer_profile, :organization, :venue, :event_seating_configuration,
          ticket_types: [
            :inventory_holds,
            :waitlist_offers,
            { event_seats: :active_precheckout_seat_holds },
            { pricing_tiers: [:inventory_holds, :waitlist_offers, :active_precheckout_seat_holds] }
          ]
        )
          .order(starts_at: :asc)
        pagy, paginated_events = paginate(events)
        preload_viewer_state(paginated_events)

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
        events = filter_named_window(events)
        events = events.where("LOWER(events.venue_city) = ?", params[:village].to_s.strip.downcase) if params[:village].present?
        events = events.joins(:venue).where(venues: { slug: params[:venue] }) if params[:venue].present?
        events = events.joins(:organization).where(organizations: { slug: params[:organizer] }) if params[:organizer].present?
        events = filter_price(events)
        events
      end

      def filter_named_window(events)
        zone = ActiveSupport::TimeZone["Pacific/Guam"]
        case params[:window]
        when "tonight"
          events.where(starts_at: Time.current..zone.now.end_of_day)
        when "weekend"
          date = zone.today
          offset = case date.wday
          when 5 then 0
          when 6 then -1
          when 0 then -2
          else 5 - date.wday
          end
          friday = date + offset
          events.where(starts_at: zone.local(friday.year, friday.month, friday.day).beginning_of_day..
            zone.local((friday + 2).year, (friday + 2).month, (friday + 2).day).end_of_day)
        else
          events
        end
      end

      def filter_price(events)
        cents = case params[:price]
        when "free" then 0
        when "under_25" then 2500
        when "under_50" then 5000
        else return events
        end
        if params[:price] == "free"
          events.where("#{EFFECTIVE_TICKET_PRICE_SQL} = :price_cents", price_at: Time.current, price_cents: cents)
        else
          events.where("#{EFFECTIVE_TICKET_PRICE_SQL} <= :price_cents", price_at: Time.current, price_cents: cents)
        end
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

      def preload_viewer_state(events)
        return unless @current_user

        event_ids = events.map(&:id)
        organization_ids = events.map(&:organization_id)
        @favorite_event_ids = @current_user.event_favorites.where(event_id: event_ids).pluck(:event_id).to_set
        @followed_organization_ids = @current_user.organizer_follows.where(organization_id: organization_ids)
          .pluck(:organization_id).to_set
        @reminders_by_event = @current_user.event_reminders.pending.where(event_id: event_ids).pluck(:event_id, :remind_at).to_h
      end

      def favorited?(event)
        return false unless @current_user
        return @favorite_event_ids.include?(event.id) if @favorite_event_ids

        @current_user.event_favorites.exists?(event_id: event.id)
      end

      def followed?(event)
        return false unless @current_user
        return @followed_organization_ids.include?(event.organization_id) if @followed_organization_ids

        @current_user.organizer_follows.exists?(organization_id: event.organization_id)
      end

      def reminder_for(event)
        return unless @current_user
        return @reminders_by_event[event.id] if @reminders_by_event

        @current_user.event_reminders.pending.find_by(event_id: event.id)&.remind_at
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
          assigned_seating: event.assigned_seating?,
          supported_locales: event.supported_locales,
          localized_content: event.localized_content,
          catalog_items: event.catalog_items.available.map { |item| catalog_item_json(item) },
          registration_questions: event.registration_questions.published.map { |question| registration_question_json(question) },
          waivers: event.event_waivers.published.map { |waiver| waiver_json(waiver) },
          attendees_preview: event.show_attendees ? active_tickets.limit(10).pluck(:attendee_name).map { |name| anonymize_name(name) } : [],
          purchasable: event.sales_open? && event.has_available_inventory?,
          organizer: {
            id: event.organization_id,
            business_name: event.organizer_profile.business_name,
            slug: event.organization.slug,
            logo_url: event.organizer_profile.logo_url,
            verified: event.organizer_profile.verification_status_verified?,
            followed: followed?(event)
          },
          venue: event.venue && {
            id: event.venue.id, name: event.venue.name, slug: event.venue.slug,
            village: event.venue.village, verified: event.venue.verified
          },
          favorited: favorited?(event),
          reminder: reminder_for(event),
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
                remaining: active_tier.remaining_quantity,
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
