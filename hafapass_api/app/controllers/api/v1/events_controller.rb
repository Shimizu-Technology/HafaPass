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
                AND (pricing_tiers.ends_at IS NULL OR pricing_tiers.ends_at > :price_at))
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

      PUBLIC_CACHE_TTL = 15.seconds
      MAX_SHOW_SLUG_LENGTH = 120
      MAX_CACHE_FILTER_SLUG_LENGTH = 100
      ALLOWED_PRICE_FILTERS = %w[free under_25 under_50].freeze
      ALLOWED_WINDOW_FILTERS = %w[tonight weekend].freeze
      CACHEABLE_SLUG_FORMAT = /\A[a-z0-9]+(?:-[a-z0-9]+)*\z/
      EVENT_SERIALIZATION_PRELOADS = [
        :organizer_profile, :organization, :venue, :event_seating_configuration,
        :catalog_items, :registration_questions, :event_waivers,
        { event_series_memberships: :event_series, ticket_types: :pricing_tiers }
      ].freeze
      ATTENDEES_PREVIEW_SQL = <<~SQL.squish.freeze
        SELECT event_id, attendee_name
        FROM (
          SELECT event_id, attendee_name,
                 ROW_NUMBER() OVER (PARTITION BY event_id ORDER BY id ASC) AS rn
          FROM tickets
          WHERE event_id IN (?) AND status <> ?
        ) ranked_tickets
        WHERE rn <= 10
        ORDER BY event_id ASC, rn ASC
      SQL

      skip_before_action :authenticate_user!
      # Set cache and Vary headers before auth/action execution so early exits (400/503) also include them.
      prepend_before_action :set_vary_headers
      prepend_before_action :set_public_cache_headers, only: [:index, :show]
      before_action :optional_authenticate!, only: [:index, :show]

      def index
        payload = if index_cacheable_request?
          Rails.cache.fetch(index_cache_key) do |_key, options|
            at = Time.current
            options.expires_at = index_cache_deadline(at)
            build_index_payload(at: at)
          end
        else
          build_index_payload
        end

        set_pagination_headers_from_meta(payload[:meta])
        render json: payload.merge(server_now: Time.current.utc.iso8601(3))
      end

      def categories
        render json: {
          categories: Event::CATEGORY_LABELS.map { |value, label| { value: value, label: label } }
        }
      end

      # A retired link name resolves to the event's current one. The JSON keeps
      # the canonical `slug` and adds `redirected_from` so the SPA can replace
      # the address bar without a second request.
      def show
        if params[:live_money_proof] == "true" && @current_user&.admin?
          event = Event.find_by_public_slug!(params[:slug], scope: Event.where(live_money_proof_candidate: true))
          render json: prepare_show_json(event).merge(server_now: Time.current.utc.iso8601(3))
          return
        end
        # Allow organizers to preview their own draft events
        if params[:preview] == "true" && @current_user
          event = Event.find_by_public_slug!(params[:slug])
          organizer_profile = @current_user.organizer_profile
          if organizer_profile && event.organizer_profile_id == organizer_profile.id
            render json: prepare_show_json(event).merge(server_now: Time.current.utc.iso8601(3))
            return
          end
        end

        payload = if show_cacheable_request?
          Rails.cache.fetch(show_cache_key) do |_key, options|
            event = Event.find_by_public_slug!(params[:slug], scope: Event.publicly_showable)
            at = Time.current
            json = prepare_show_json(event, at: at)
            options.expires_at = show_cache_deadline(event, at)
            json
          end
        else
          event = Event.find_by_public_slug!(params[:slug], scope: Event.publicly_showable)
          prepare_show_json(event)
        end

        render json: payload.merge(server_now: Time.current.utc.iso8601(3))
      rescue ActiveRecord::RecordNotFound
        render json: { error: "Event not found" }, status: :not_found
      end

      def private_preview
        response.headers["X-Robots-Tag"] = "noindex, nofollow, noarchive"
        response.headers["Cache-Control"] = "private, no-store"
        response.headers["Referrer-Policy"] = "no-referrer"
        event = Event.find_by_public_slug!(params[:slug])
        raise ActiveRecord::RecordNotFound unless event.private_preview_eligible? &&
          params[:token].blank? && event.valid_preview_token?(request.headers["X-Preview-Token"])

        if event.publicly_visible?
          render json: { redirect_to: event.slug }
        else
          render json: prepare_show_json(event).merge(private_preview: true, purchasable: false)
        end
      rescue ActiveRecord::RecordNotFound
        render json: { error: "Event not found" }, status: :not_found
      end

      private

      def set_public_cache_headers
        response.headers["Cache-Control"] = "private, no-store"
      end

      def set_vary_headers
        values = %w[index show].include?(action_name) ? %w[Accept-Language Authorization] : %w[Accept-Language]
        existing = response.headers["Vary"].to_s.split(",").map(&:strip).reject(&:empty?)
        values.each do |value|
          existing << value unless existing.any? { |entry| entry.casecmp?(value) }
        end
        response.headers["Vary"] = existing.join(", ")
      end

      def public_cacheable_request?
        @current_user.nil? &&
          request.authorization.blank? &&
          params[:preview] != "true" &&
          params[:live_money_proof] != "true"
      end

      def index_cacheable_request?
        return false unless public_cacheable_request?
        return false if params[:q].present?
        return false if %i[organizer series venue village].any? { |key| params[key].to_s.length > MAX_CACHE_FILTER_SLUG_LENGTH }

        true
      end

      def show_cacheable_request?
        return false unless public_cacheable_request?

        raw_slug = params[:slug].to_s
        return false if raw_slug.blank? || raw_slug.length > MAX_SHOW_SLUG_LENGTH
        return false unless raw_slug == Event.normalize_public_slug(raw_slug)

        raw_series = params[:series]
        if raw_series.present?
          series_str = raw_series.to_s
          return false if series_str.length > MAX_CACHE_FILTER_SLUG_LENGTH || !CACHEABLE_SLUG_FORMAT.match?(series_str)
        end

        true
      end

      def site_setting_cache_version
        updated_at = SiteSetting.pick(:updated_at) || listing_settings.updated_at
        updated_at&.utc&.iso8601(6).to_s
      end

      def normalized_page_param
        page = params[:page].to_i
        page.positive? ? page : 1
      end

      def normalized_per_page_param
        per_page = params[:per_page].to_i
        return Pagy::DEFAULT[:limit] unless per_page.positive?

        per_page.clamp(1, Pagy::DEFAULT[:max_limit])
      end

      def normalized_index_cache_params
        {
          "category" => Event.categories.key?(params[:category].to_s) ? params[:category].to_s : nil,
          "date_from" => params[:date_from].to_s.presence,
          "date_to" => params[:date_to].to_s.presence,
          "featured" => ActiveModel::Type::Boolean.new.cast(params[:featured]) ? true : nil,
          "include_sold_out" => include_sold_out? ? true : nil,
          "organizer" => params[:organizer].to_s.presence,
          "page" => normalized_page_param,
          "per_page" => normalized_per_page_param,
          "price" => ALLOWED_PRICE_FILTERS.include?(params[:price].to_s) ? params[:price].to_s : nil,
          "series" => params[:series].to_s.presence,
          "venue" => params[:venue].to_s.presence,
          "village" => params[:village].to_s.presence,
          "window" => ALLOWED_WINDOW_FILTERS.include?(params[:window].to_s) ? params[:window].to_s : nil
        }.compact
      end

      def normalized_show_cache_params
        raw_series = params[:series]
        return {} if raw_series.blank?

        { "series" => raw_series.to_s }
      end

      def index_cache_key
        [
          "public_events/v2/index",
          request_locale.to_s,
          I18n.locale.to_s,
          site_setting_cache_version,
          normalized_index_cache_params
        ]
      end

      def show_cache_key
        [
          "public_events/v2/show",
          params[:slug].to_s,
          request_locale.to_s,
          I18n.locale.to_s,
          site_setting_cache_version,
          normalized_show_cache_params
        ]
      end

      # Discovery can change when a boundary is reached, including for
      # events excluded from the current page or price filter.
      def index_cache_deadline(at)
        limit = at + PUBLIC_CACHE_TTL
        upcoming = at..limit
        boundaries = [
          TicketType.where(sales_start_at: upcoming).select("sales_start_at AS cutoff"),
          TicketType.where(sales_end_at: upcoming).select("sales_end_at AS cutoff"),
          PricingTier.time_based.where(starts_at: upcoming).select("starts_at AS cutoff"),
          PricingTier.time_based.where(ends_at: upcoming).select("ends_at AS cutoff")
        ].map(&:to_sql).join(" UNION ALL ")
        Event.with_connection do |connection|
          connection.select_value(
            "SELECT MIN(cutoff) FROM (#{boundaries}) schedule_boundaries WHERE cutoff > #{connection.quote(at)}"
          ) || limit
        end
      end

      def show_cache_deadline(event, at)
        cutoffs = event.ticket_types.flat_map do |ticket_type|
          [ticket_type.sales_start_at, ticket_type.sales_end_at] +
            ticket_type.pricing_tiers.select(&:time_based?).flat_map { |tier| [tier.starts_at, tier.ends_at] }
        end
        cutoffs << (at + PUBLIC_CACHE_TTL)
        cutoffs.compact.select { |cutoff| cutoff > at }.min
      end

      def build_index_payload(at: Time.current)
        events = filtered_events(at: at).preload(*EVENT_SERIALIZATION_PRELOADS).order(starts_at: :asc)
        pagy, paginated_events = paginate(events, items: normalized_per_page_param)
        records = paginated_events.to_a
        preload_event_stats(records, at: at)
        preload_viewer_state(records)

        {
          events: records.map { |event| event_json(event, include_ticket_types: true, at: at) },
          meta: pagination_meta(pagy)
        }
      end

      def set_pagination_headers_from_meta(meta)
        response.set_header("X-Total-Count", meta[:total_count].to_s)
        response.set_header("X-Total-Pages", meta[:total_pages].to_s)
        response.set_header("X-Page", meta[:current_page].to_s)
        response.set_header("X-Per-Page", meta[:per_page].to_s)
      end

      def prepare_show_json(event, at: Time.current)
        ActiveRecord::Associations::Preloader.new(records: [event], associations: EVENT_SERIALIZATION_PRELOADS).call
        preload_event_stats([event], at: at)
        show_json(event, at: at)
      end

      def show_json(event, at: Time.current)
        json = event_json(event, include_ticket_types: true, include_design: true, at: at)
        json[:redirected_from] = params[:slug] if event.slug != params[:slug]
        json
      end

      def include_sold_out?
        params[:include_sold_out] == "true" && (params[:organizer].present? || params[:series].present?)
      end

      def filtered_events(at:)
        events = include_sold_out? ? Event.discoverable_base(at) : Event.discoverable(at)
        if params[:q].present?
          events = events.accent_insensitive_search(params[:q], :title, :description, :short_description,
            :venue_name, :venue_city)
        end
        events = events.where(category: params[:category]) if Event.categories.key?(params[:category].to_s)
        events = events.where(is_featured: true) if ActiveModel::Type::Boolean.new.cast(params[:featured])
        events = events.where(starts_at: parse_date_boundary(params[:date_from], beginning: true)..) if params[:date_from].present?
        events = events.where(starts_at: ..parse_date_boundary(params[:date_to], beginning: false)) if params[:date_to].present?
        events = filter_named_window(events)
        events = events.accent_insensitive_equals(:venue_city, params[:village]) if params[:village].present?
        events = events.joins(:venue).where(venues: { slug: params[:venue] }) if params[:venue].present?
        events = events.joins(:organization).where(organizations: { slug: params[:organizer] }) if params[:organizer].present?
        if params[:series].present?
          raise ActionController::BadRequest, "organizer parameter is required when filtering by series" if params[:organizer].blank?

          events = events.joins(:event_series)
            .merge(EventSeries.publicly_visible)
            .where(event_series: { slug: params[:series] })
            .distinct
        end
        events = filter_price(events, at: at)
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

      # The all-in price buyers see on cards: the effective ticket price plus
      # the buyer's share of the service fee, with Commerce::ServiceFee's
      # per-ticket half-up rounding (PostgreSQL ROUND on numeric rounds half
      # away from zero, which is half up for these non-negative amounts).
      ALL_IN_TICKET_PRICE_SQL = <<~SQL.squish.freeze
        (SELECT effective.price_cents + CASE WHEN effective.price_cents > 0 THEN
            ROUND((ROUND(effective.price_cents * CAST(:fee_percent AS numeric) / 100) + :fee_flat_cents)
              * events.buyer_fee_percent / 100.0)
          ELSE 0 END
         FROM (SELECT #{EFFECTIVE_TICKET_PRICE_SQL} AS price_cents) effective)
      SQL

      def filter_price(events, at:)
        cents = case params[:price]
        when "free" then 0
        when "under_25" then 2500
        when "under_50" then 5000
        else return events
        end
        operator = params[:price] == "free" ? "=" : "<="
        events.where("#{ALL_IN_TICKET_PRICE_SQL} #{operator} :price_cents", price_at: at, price_cents: cents,
          fee_percent: listing_fee_terms.percent.to_s, fee_flat_cents: listing_fee_terms.flat_cents)
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

      def preload_event_stats(events, at: Time.current)
        @active_ticket_counts = Hash.new(0)
        @pass_committed_counts = {}
        @preloaded_events_by_id = events.index_by(&:id)
        @extra_included_event_remaining = {}
        @event_hold_counts = Hash.new(0)
        @ticket_type_hold_counts = Hash.new(0)
        @pricing_tier_hold_counts = Hash.new(0)
        @event_waitlist_counts = Hash.new(0)
        @ticket_type_waitlist_counts = Hash.new(0)
        @pricing_tier_waitlist_counts = Hash.new(0)
        @event_seat_hold_counts = Hash.new(0)
        @ticket_type_seat_hold_counts = Hash.new(0)
        @pricing_tier_seat_hold_counts = Hash.new(0)
        @catalog_item_hold_counts = {}
        @attendees_preview_by_event = Hash.new { |hash, key| hash[key] = [] }
        return if events.empty?

        event_ids = events.map(&:id)
        pass_child_ticket_counts = Hash.new(0)
        Ticket.where(event_id: event_ids).where.not(status: :cancelled)
          .group(:event_id, Arel.sql("parent_ticket_id IS NOT NULL")).count
          .each do |(event_id, is_pass_child), count|
            @active_ticket_counts[event_id] += count
            pass_child_ticket_counts[event_id] += count if is_pass_child
          end

        capacity_event_ids = events.select { |event| event.max_capacity.present? }.map(&:id)
        if capacity_event_ids.any?
          @pass_committed_counts = EventCapacity.pass_committed_by_event_ids(
            capacity_event_ids,
            at: at,
            child_counts: pass_child_ticket_counts
          )
        end

        pass_ticket_types = events.flat_map { |event| event.ticket_types.select(&:is_pass?) }
        if pass_ticket_types.any?
          ActiveRecord::Associations::Preloader.new(
            records: pass_ticket_types,
            associations: { ticket_type_included_events: :included_event }
          ).call

          extra_included_events = pass_ticket_types
            .flat_map { |tt| tt.ticket_type_included_events.filter_map(&:included_event) }
            .reject { |included| included.max_capacity.blank? || @preloaded_events_by_id.key?(included.id) }
            .uniq(&:id)
          if extra_included_events.any?
            @extra_included_event_remaining = EventCapacity.remaining_for_events(extra_included_events, at: at)
          end
        end

        InventoryHold.active.where(event_id: event_ids).where("expires_at > ?", at)
          .group(:event_id, :ticket_type_id, :pricing_tier_id).sum(:quantity)
          .each do |(event_id, ticket_type_id, pricing_tier_id), qty|
            @event_hold_counts[event_id] += qty
            @ticket_type_hold_counts[ticket_type_id] += qty
            @pricing_tier_hold_counts[pricing_tier_id] += qty if pricing_tier_id
          end

        WaitlistOffer.holding_inventory(at).where(event_id: event_ids)
          .group(:event_id, :ticket_type_id, :pricing_tier_id).sum(:quantity)
          .each do |(event_id, ticket_type_id, pricing_tier_id), qty|
            @event_waitlist_counts[event_id] += qty
            @ticket_type_waitlist_counts[ticket_type_id] += qty
            @pricing_tier_waitlist_counts[pricing_tier_id] += qty if pricing_tier_id
          end

        event_id_by_seating_config = events.each_with_object({}) do |event, map|
          config = event.event_seating_configuration
          map[config.id] = event.id if config
        end
        if event_id_by_seating_config.any?
          SeatHold.status_active.joins(:seat_hold_session, :event_seat)
            .where(event_seats: { event_seating_configuration_id: event_id_by_seating_config.keys })
            .where(seat_hold_sessions: { status: SeatHoldSession.statuses[:active] })
            .where("seat_hold_sessions.expires_at > ?", at)
            .group("event_seats.event_seating_configuration_id", "event_seats.ticket_type_id", "seat_holds.pricing_tier_id")
            .count
            .each do |(seating_config_id, ticket_type_id, pricing_tier_id), qty|
              event_id = event_id_by_seating_config[seating_config_id]
              @event_seat_hold_counts[event_id] += qty if event_id
              @ticket_type_seat_hold_counts[ticket_type_id] += qty
              @pricing_tier_seat_hold_counts[pricing_tier_id] += qty if pricing_tier_id
            end
        end

        tracked_catalog_item_ids = events.flat_map do |event|
          event.catalog_items.select { |item| item.active? && item.inventory_quantity.present? }.map(&:id)
        end
        if tracked_catalog_item_ids.any?
          @catalog_item_hold_counts = CatalogItemHold.current
            .where(catalog_item_id: tracked_catalog_item_ids).group(:catalog_item_id).sum(:quantity)
        end

        show_attendee_event_ids = events.select(&:show_attendees?).map(&:id)
        return if show_attendee_event_ids.empty?

        sanitized_sql = ActiveRecord::Base.sanitize_sql_array([
          ATTENDEES_PREVIEW_SQL,
          show_attendee_event_ids,
          Ticket.statuses.fetch("cancelled")
        ])
        Ticket.connection.select_rows(sanitized_sql).each do |event_id, attendee_name|
          @attendees_preview_by_event[event_id.to_i] << anonymize_name(attendee_name)
        end
      end

      def event_remaining_capacity(event)
        return Float::INFINITY if event.max_capacity.blank?

        sold = event.ticket_types.sum(&:quantity_sold)
        held = @event_hold_counts[event.id] + @event_waitlist_counts[event.id] + @event_seat_hold_counts[event.id]
        pass_committed = @pass_committed_counts.fetch(event.id, 0)
        [event.max_capacity - sold - held - pass_committed, 0].max
      end

      def ticket_type_available_quantity(ticket_type)
        held = @ticket_type_hold_counts[ticket_type.id] +
          @ticket_type_waitlist_counts[ticket_type.id] +
          @ticket_type_seat_hold_counts[ticket_type.id]
        remaining = [ticket_type.quantity_available - ticket_type.quantity_sold - held, 0].max
        return remaining unless ticket_type.is_pass?

        bottleneck = pass_included_events_bottleneck(ticket_type)
        bottleneck ? [remaining, bottleneck].min : remaining
      end

      def pass_included_events_bottleneck(ticket_type)
        links = ticket_type.ticket_type_included_events
        return nil if links.empty?

        remaining_values = links.filter_map do |link|
          included = link.included_event
          next unless included&.max_capacity.present?

          if (page_event = @preloaded_events_by_id&.[](included.id))
            event_remaining_capacity(page_event)
          else
            @extra_included_event_remaining&.fetch(included.id, Float::INFINITY)
          end
        end
        remaining_values.min
      end

      def serialized_included_events(ticket_type)
        return [] unless ticket_type.is_pass?

        ticket_type.ticket_type_included_events
          .sort_by { |link| [link.position, link.id] }
          .filter_map do |link|
            included = link.included_event
            next unless included
            next if included.draft? || included.archived? || included.policy_hold_scope == "hidden"

            Passes::TicketPayload.included_event_json(
              included,
              title: included.content_for(request_locale)[:title]
            )
          end
      end

      def pricing_tier_committed_quantity(tier)
        tier.quantity_sold +
          @pricing_tier_hold_counts[tier.id] +
          @pricing_tier_waitlist_counts[tier.id] +
          @pricing_tier_seat_hold_counts[tier.id]
      end

      def pricing_tier_active?(tier, at: Time.current)
        return pricing_tier_committed_quantity(tier) < tier.quantity_limit if tier.quantity_based?

        tier.active?(at: at)
      end

      def pricing_tier_remaining_quantity(tier)
        return unless tier.quantity_based?

        [tier.quantity_limit - pricing_tier_committed_quantity(tier), 0].max
      end

      def scheduled_tier_json(tier, event, fee: nil)
        return unless tier

        {
          id: tier.id,
          name: tier.name,
          price_cents: tier.price_cents,
          all_in_price_cents: (fee || Commerce::ServiceFee.for_event(event, tier.price_cents, terms: listing_fee_terms)).all_in_price_cents,
          starts_at: tier.starts_at&.utc&.iso8601(6),
          ends_at: tier.ends_at&.utc&.iso8601(6)
        }
      end

      def pricing_schedule(ticket_type, event, tiers, active_tier, fee, at:)
        time_tiers = tiers.select(&:time_based?).sort_by { |tier| [tier.starts_at&.to_f || -Float::INFINITY, tier.id] }
        next_tier = time_tiers.find { |tier| tier.starts_at && tier.starts_at > at }
        {
          timezone: event.timezone,
          sales_start_at: ticket_type.sales_start_at&.utc&.iso8601(6),
          sales_end_at: ticket_type.sales_end_at&.utc&.iso8601(6),
          active_tier: scheduled_tier_json(active_tier, event, fee: fee)&.merge(tier_type: active_tier.tier_type),
          next_tier: scheduled_tier_json(next_tier, event),
          time_tiers: time_tiers.map { |tier| scheduled_tier_json(tier, event) }
        }
      end

      def event_json(event, include_ticket_types: false, include_design: false, at: Time.current)
        content = event.content_for(request_locale)
        attendee_count = @active_ticket_counts.fetch(event.id, 0)
        sorted_ticket_types = event.ticket_types.sort_by { |tt| [tt.sort_order.nil? ? 1 : 0, tt.sort_order.to_i, tt.id] }
        sales_open = event.sales_open?(at: at)
        on_sale_ticket_types = sorted_ticket_types.select { |tt| tt.on_sale?(at: at) }
        has_available_inventory = sales_open && event_remaining_capacity(event).positive? &&
          on_sale_ticket_types.any? { |tt| ticket_type_available_quantity(tt).positive? }
        sold_out = sales_open && on_sale_ticket_types.any? && !has_available_inventory
        available_catalog_items = event.catalog_items.select(&:active?).sort_by { |item| [item.position, item.id] }
        published_questions = event.registration_questions.select(&:active?).sort_by { |question| [question.position, question.id] }
        published_waivers = event.event_waivers.select(&:active?).sort_by(&:id)

        json = {
          id: event.id,
          title: content[:title],
          slug: event.slug,
          description: content[:description],
          short_description: content[:short_description],
          content_locale: content[:locale],
          machine_translated: content[:machine_translated],
          original_content: content[:locale] == AppLocale::DEFAULT ? nil : event.slice(*Event::CONTENT_FIELDS),
          cover_image_url: event.cover_image_url,
          page_customization: include_design ? event.page_customization :
            (event.page_customization.is_a?(Hash) ? event.page_customization.slice("focal_point", "accent") : {}),
          image_asset_host: S3Service.public_asset_host,
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
          live_money_proof_candidate: event.live_money_proof_candidate,
          published_at: event.published_at,
          show_attendees: event.show_attendees,
          attendee_count: attendee_count,
          fee_policy: event.fee_policy,
          buyer_fee_percent: event.buyer_fee_percent,
          service_fee_includes_processing: listing_settings.platform_bears_processing?,
          transfers_enabled: event.transfers_available?,
          assigned_seating: event.assigned_seating?,
          supported_locales: event.supported_locales,
          localized_content: event.localized_content,
          catalog_items: available_catalog_items.map { |item| catalog_item_json(item) },
          registration_questions: published_questions.map { |question| registration_question_json(question) },
          waivers: published_waivers.map { |waiver| waiver_json(waiver) },
          attendees_preview: event.show_attendees? ? @attendees_preview_by_event[event.id] : [],
          purchasable: has_available_inventory,
          sold_out: sold_out,
          organizer: {
            id: event.organization_id,
            business_name: event.organizer_profile.business_name,
            slug: event.organization.slug,
            logo_url: event.organizer_profile.logo_url,
            verified: event.organizer_profile.verification_status_verified?,
            followed: followed?(event)
          },
          seller: SellerIdentity.for_event(event, platform_name: listing_settings.platform_name).as_json,
          venue: event.venue && {
            id: event.venue.id, name: event.venue.name, slug: event.venue.slug,
            village: event.venue.village, verified: event.venue.verified
          },
          series: serialized_series(event),
          favorited: favorited?(event),
          reminder: reminder_for(event),
          created_at: event.created_at,
          updated_at: event.updated_at
        }

        if include_ticket_types
          json[:ticket_types] = sorted_ticket_types.map do |tt|
            tiers = tt.pricing_tiers.sort_by { |tier| [tier.position, tier.id] }
            active_index = tiers.index { |tier| pricing_tier_active?(tier, at: at) }
            active_tier = active_index ? tiers[active_index] : nil
            # Forecast what replaces a closing window with today's cap availability.
            next_tier = if active_tier&.time_based? && active_tier.ends_at
              tiers.find { |tier| pricing_tier_active?(tier, at: active_tier.ends_at) }
            elsif active_index
              tiers[active_index + 1]
            else
              tiers.find { |tier| tier.time_based? && tier.starts_at.present? && tier.starts_at > at }
            end
            tt_content = tt.content_for(request_locale)
            current_price_cents = active_tier ? active_tier.price_cents : tt.price_cents
            fee = Commerce::ServiceFee.for_event(event, current_price_cents, terms: listing_fee_terms)
            quantity_remaining = ticket_type_available_quantity(tt)
            tt_json = {
              id: tt.id,
              name: tt_content[:name],
              description: tt_content[:description],
              machine_translated: tt_content[:machine_translated],
              original_name: tt.name,
              original_description: tt.description,
              price_cents: tt.price_cents,
              current_price_cents: current_price_cents,
              original_price_cents: tt.price_cents,
              # All-in prices include the mandatory per-ticket service fee the
              # buyer pays under the event's fee policy, computed by the same
              # code as checkout. Displays lead with these (16 CFR Part 464).
              all_in_price_cents: fee.all_in_price_cents,
              service_fee_cents: fee.buyer_fee_cents,
              regular_all_in_price_cents: Commerce::ServiceFee.for_event(event, tt.price_cents, terms: listing_fee_terms).all_in_price_cents,
              quantity_available: tt.quantity_available,
              quantity_sold: tt.quantity_sold,
              quantity_remaining: quantity_remaining,
              sold_out: quantity_remaining.zero?,
              on_sale: sales_open && tt.on_sale?(at: at),
              max_per_order: tt.max_per_order,
              max_per_buyer: tt.max_per_buyer,
              sales_start_at: tt.sales_start_at,
              sales_end_at: tt.sales_end_at,
              is_pass: tt.is_pass?,
              included_events: serialized_included_events(tt)
            }
            if active_tier
              tt_json[:active_tier] = {
                name: active_tier.name,
                tier_type: active_tier.tier_type,
                remaining: pricing_tier_remaining_quantity(active_tier),
                ends_at: active_tier.ends_at
              }
            end
            if next_tier
              tt_json[:next_tier] = {
                name: next_tier.name,
                price_cents: next_tier.price_cents,
                all_in_price_cents: Commerce::ServiceFee.for_event(event, next_tier.price_cents, terms: listing_fee_terms).all_in_price_cents
              }
            end
            if tiers.any? || tt.sales_start_at || tt.sales_end_at
              tt_json[:pricing_schedule] = pricing_schedule(tt, event, tiers, active_tier, fee, at: at)
            end
            tt_json
          end
        end

        json
      end

      def catalog_item_json(item)
        quantity_remaining = if item.inventory_quantity
          held = @catalog_item_hold_counts.fetch(item.id, 0)
          [item.inventory_quantity - item.quantity_sold - held, 0].max
        end
        {
          id: item.id, name: item.name, description: item.description, kind: item.kind,
          price_cents: item.price_cents, minimum_price_cents: item.minimum_price_cents,
          maximum_price_cents: item.maximum_price_cents,
          quantity_remaining: quantity_remaining
        }
      end

      def registration_question_json(question)
        { id: question.id, prompt: question.prompt, kind: question.kind, required: question.required, options: question.options }
      end

      def waiver_json(waiver)
        { id: waiver.id, title: waiver.title, body: waiver.body, version: waiver.version, required: waiver.required }
      end

      def serialized_series(event)
        public_memberships = event.event_series_memberships.select { |m| m.event_series&.publicly_visible? }
        membership = if params[:series].present?
          public_memberships.find { |m| m.event_series.slug == params[:series].to_s } || public_memberships.first
        else
          public_memberships.first
        end
        return nil unless membership

        series = membership.event_series

        {
          id: series.id,
          slug: series.slug,
          name: series.name,
          role: membership.role
        }
      end
    end
  end
end
