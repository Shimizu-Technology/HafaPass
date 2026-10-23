module Api
  module V1
    module Organizer
      class EventsController < BaseController
        include CancellationRefundActions
        include Paginatable

        before_action :set_event, only: [
          :show, :update, :destroy, :publish, :postpone, :resume, :cancel, :complete, :archive,
          :clone, :generate_recurrences, :stats, :attendees, :slug_availability, :retranslate,
          :cancellation_refunds, :retry_cancellation_refunds, :mark_cash_refunded,
          :preview_link, :rotate_preview_link
        ]

        def index
          events = OrganizationAuthorization.accessible_events(user: current_user, organization: current_organization)
            .includes(:organization, :organizer_profile, :event_seating_configuration,
              ticket_types: [:waitlist_offers, { pricing_tiers: [:inventory_holds, :waitlist_offers,
                :active_precheckout_seat_holds] }, { inventory_holds: :order }, { tickets: :order },
                { event_seats: :active_precheckout_seat_holds }])
            .order(created_at: :desc, id: :desc)
          if params[:purpose] == "scan" && !OrganizationAuthorization.allowed?(user: current_user, organization: current_organization, permission: :scan)
            assigned_ids = current_organization.event_staff_assignments.effective.where(user: current_user, role: [:manager, :box_office, :scanner]).select(:event_id)
            events = events.where(id: assigned_ids)
          end
          query = params[:q].to_s.strip.first(200)
          if query.present?
            matches = events.accent_insensitive_search(query, :title, :venue_name, :slug)
            events = query.match?(/\A\d+\z/) ? matches.or(events.where(id: query.to_i)) : matches
          end
          events = filter_and_order_index(events)
          pagy, paginated_events = paginate(events, items: params.fetch(:per_page, 20).to_i.clamp(1, 100))

          @event_permission_maps = OrganizationAuthorization.permissions_for_events(
            user: current_user, organization: current_organization, events: paginated_events.to_a
          )
          render json: {
            events: paginated_events.map { |event| event_json(event, include_ticket_types: true) },
            meta: pagination_meta(pagy)
          }
        end

        def show
          render json: event_json(@event, include_ticket_types: true)
        end

        def preview_link
          return unless authorize_organization!(:manage_events, event: @event)
          return head :not_found unless @event.private_preview_eligible?

          render json: { url: "#{PublicSiteUrl.base}/events/#{@event.slug}/preview#t=#{@event.preview_token}" }
        end

        def rotate_preview_link
          return unless authorize_organization!(:manage_events, event: @event)
          return head :not_found unless @event.private_preview_eligible?

          token = @event.rotate_preview_token!
          AuditLogger.record!(action: "event.preview_link_rotated", auditable: @event, actor: current_user,
            organization: current_organization, request: request)
          render json: { url: "#{PublicSiteUrl.base}/events/#{@event.slug}/preview#t=#{token}" }
        end

        # Organization-wide home totals, scoped to the events this user may see.
        # Money stays hidden unless the membership itself grants view_finance.
        def summary
          events = OrganizationAuthorization.accessible_events(user: current_user, organization: current_organization)
          # An event that has started but not ended still counts, so it stays
          # on the home summary through show night.
          upcoming = events.published.where("COALESCE(events.ends_at, events.starts_at) > ?", Time.current)
          next_event = upcoming.order(:starts_at, :id).first
          json = {
            upcoming_events_count: upcoming.count,
            tickets_sold: Ticket.where(event_id: events.select(:id)).where.not(status: :cancelled).count,
            next_event: next_event && {
              id: next_event.id, title: next_event.title, starts_at: next_event.starts_at, timezone: next_event.timezone
            }
          }
          if OrganizationAuthorization.allowed?(user: current_user, organization: current_organization, permission: :view_finance)
            json[:revenue_cents] = Commerce::LedgerTotals.call(Order.where(event_id: events.select(:id)))[:net_cents]
          end
          render json: json
        end

        def create
          return unless authorize_organization!(:manage_events)

          event = current_organization.events.build(parsed_event_params)
          event.transfers_enabled = false unless LaunchCapabilities.enabled?(:ticket_transfers)
          event.organizer_profile = current_organizer_profile
          if event.save
            render json: event_json(event), status: :created
          else
            render json: { errors: event.errors.full_messages }, status: :unprocessable_entity
          end
        rescue ActiveRecord::RecordNotUnique => e
          render_link_conflict(e)
        end

        def update
          updated = false
          Event.transaction do
            # Checkout takes the event before ticket types. NO KEY UPDATE also
            # permits foreign-key checks from payment finalization while it
            # finishes consuming a hold under the ticket-type lock.
            @event.lock!("FOR NO KEY UPDATE")
            @event.ticket_types.order(:id).lock.load
            attributes = parsed_event_params
            can_manage = OrganizationAuthorization.allowed?(
              user: current_user, organization: current_organization, permission: :manage_events, event: @event
            )
            unless can_manage
              attributes.slice!("title", "slug", "description", "short_description", "cover_image_url", "category", "page_customization")
            end
            attributes["transfers_enabled"] = false if can_manage && !LaunchCapabilities.enabled?(:ticket_transfers)
            reschedule = reschedule?(attributes)
            change_reason = params[:change_reason].to_s.strip.presence
            if reschedule && change_reason.blank?
              return render json: { error: "A reason is required when changing the schedule of a published or postponed event" },
                status: :unprocessable_entity
            end

            before_data = event_change_snapshot(@event) if reschedule
            previous_design = @event.page_customization.deep_dup if attributes.key?("page_customization")
            updated = @event.update(attributes)
            if updated && previous_design && previous_design != @event.page_customization
              AuditLogger.record!(action: "event.page_customized", auditable: @event, actor: current_user,
                before_data: { page_customization: previous_design },
                after_data: { page_customization: @event.page_customization }, request: request)
            end
            if updated && reschedule
              event_change = @event.event_changes.create!(
                actor_user: current_user,
                change_type: "rescheduled",
                reason: change_reason,
                before_data: before_data,
                after_data: event_change_snapshot(@event),
                occurred_at: Time.current
              )
              EmailService.send_event_change_notifications_async(event_change)
            end
          end
          if updated
            render json: event_json(@event)
          else
            render json: { errors: @event.errors.full_messages }, status: :unprocessable_entity
          end
        rescue ActiveRecord::RecordNotUnique => e
          # The rollback already happened; report the lost link race like the
          # availability check would have, so the form shows it on the field.
          render_link_conflict(e)
        end

        # Re-runs machine translation for the event and its ticket types, for
        # example after General Translation was first configured.
        def retranslate
          outcome = Event.retranslate_with_ticket_types(@event)
          unless outcome == :queued
            message, status = Event::RETRANSLATE_REFUSALS.fetch(outcome)
            return render json: { error: message, code: outcome.to_s }, status: status
          end

          render json: { translation_status: @event.reload.translation_status }, status: :accepted
        end

        def destroy
          unless @event.draft?
            return render json: { error: "Only draft events can be deleted; archive or cancel this event instead" },
              status: :unprocessable_entity
          end

          if @event.destroy
            head :no_content
          else
            render json: { error: "This event has saved history or related records and cannot be deleted. Archive it instead to keep those records." }, status: :unprocessable_entity
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
          preview = EventCancellationRefunds.preview(@event)
          if !params.key?(:refund_count) || !params.key?(:refund_total_cents) ||
              params[:refund_count].to_i != preview[:count] || params[:refund_total_cents].to_i != preview[:total_cents]
            return render json: { error: "Refund total changed. Review the current count and amount before cancelling.",
              preview: preview }, status: :conflict
          end
          transition_event(:cancel)
        end

        def complete
          transition_event(:complete)
        end

        def archive
          transition_event(:archive)
        end

        def clone
          return render_policy_hold_refusal("copied") if @event.policy_hold?

          cloned = clone_event(@event, title: "#{@event.title} (Copy)", starts_at: nil, ends_at: nil, doors_open_at: nil)
          if cloned.persisted?
            render json: event_json(cloned, include_ticket_types: true), status: :created
          else
            render json: { errors: cloned.errors.full_messages }, status: :unprocessable_entity
          end
        end

        def generate_recurrences
          return render_policy_hold_refusal("repeated") if @event.policy_hold?

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

        # Lets the edit form check a link name as the organizer types, using the
        # same rules the save applies (format, reserved words, current and
        # retired links of other events).
        def slug_availability
          candidate = Event.normalize_public_slug(params[:slug])
          problem = candidate == @event.slug ? nil : Event.public_slug_problem(candidate, record: @event)
          render json: {
            slug: candidate,
            available: problem.nil?,
            message: problem && "#{Event.human_attribute_name(:slug)} #{problem}"
          }
        end

        def stats
          tickets = @event.tickets
          orders = @event.orders.excluding_test_payments.where(status: [:completed, :partially_refunded, :refunded])
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

          analytics = EventSalesAnalytics.call(@event)
          render json: {
            total_tickets_sold: total_tickets_sold,
            total_revenue_cents: total_revenue_cents,
            financials: financials,
            tickets_checked_in: tickets_checked_in,
            tickets_by_type: tickets_by_type,
            recent_orders: recent_orders,
            marketplace_funnel: @event.marketplace_funnel_events.group(:stage).count,
            acquisition_sources: @event.orders.joins(:acquisition_attribution)
              .group("acquisition_attributions.source", "acquisition_attributions.medium", "acquisition_attributions.campaign")
              .count.map { |(source, medium, campaign), count|
                { source: source, medium: medium, campaign: campaign, orders: count }
              }
          }.merge(analytics)
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
          query = OrganizerSalesQuery.new(event: @event, params: params, attendee_access: @can_view_attendees)
          pagy, records = paginate(query.relation, items: params.fetch(:per_page, 25).to_i.clamp(1, 100))
          can_view_finance = OrganizationAuthorization.allowed?(user: current_user, organization: current_organization,
            permission: :view_finance, event: @event)
          can_view_attendees = @can_view_attendees
          response.headers["Cache-Control"] = "no-store"
          render json: {
            attendees: records.includes(query.view == "orders" ? [{ tickets: :ticket_type }, :promo_code] : [:ticket_type, { order: :payments }]).map { |record|
              if record.is_a?(Order)
                row = { id: record.id,
                  order_number: record.reference, ticket_type: record.tickets.map { |ticket| ticket.ticket_type.name }.uniq.join(", "),
                  status: record.status, sales_status_label: OrganizerTicketSalesStatus.label(record.status), purchase_date: record.completed_at || record.created_at,
                  channel: FinanceExports.channel(record), ticket_count: record.tickets.size,
                  checked_in_count: record.tickets.count(&:checked_in?) }
                row.merge!(attendee_name: record.buyer_name, attendee_email: record.buyer_email,
                  checked_in_at: record.tickets.filter_map(&:checked_in_at).max) if can_view_attendees
                row[:amount_cents] = record.total_cents if can_view_finance
                row
              else
                sales_status = OrganizerTicketSalesStatus.for(record, event_cancelled: @event.cancelled?)
                row = { id: record.id,
                  ticket_type: record.ticket_type.name, status: record.status, sales_status: sales_status,
                  sales_status_label: OrganizerTicketSalesStatus.label(sales_status),
                  order_id: record.order_id, order_number: record.order.reference,
                  purchase_date: record.order.completed_at || record.order.created_at,
                  channel: FinanceExports.channel(record.order), test_payment: record.order.test_payment? }
                row.merge!(attendee_name: record.attendee_name,
                  attendee_email: record.holder_email.presence || record.attendee_email,
                  checked_in_at: record.checked_in_at) if can_view_attendees
                row
              end
            },
            meta: pagination_meta(pagy)
          }
        rescue OrganizerSalesQuery::InvalidFilter => error
          render json: { error: error.message }, status: :unprocessable_entity
        end

        private

        # Optional narrowing used by the door scanner to find its default event
        # across pages. Filters apply after access scoping, so they never widen
        # what the caller may see; unknown values are ignored.
        def filter_and_order_index(events)
          events = events.where(status: params[:status]) if Event.statuses.key?(params[:status].to_s)
          ends_after = index_time_param(:ends_after)
          events = events.where("COALESCE(events.ends_at, events.starts_at) >= ?", ends_after) if ends_after
          case params[:order]
          when "starts_at" then events.reorder(Arel.sql("events.starts_at ASC NULLS LAST, events.id ASC"))
          when "-starts_at" then events.reorder(Arel.sql("events.starts_at DESC NULLS LAST, events.id DESC"))
          else events
          end
        end

        def index_time_param(key)
          Time.zone.iso8601(params[key].to_s) if params[key].present?
        rescue ArgumentError
          nil
        end

        def transition_event(action)
          EventLifecycle.call(event: @event, action: action, actor: current_user, reason: params[:reason],
            expected_refund_count: action == :cancel ? params[:refund_count].to_i : nil,
            expected_refund_total_cents: action == :cancel ? params[:refund_total_cents].to_i : nil)
          render json: event_json(@event.reload, include_ticket_types: true)
        rescue EventLifecycle::TransitionError => e
          render json: { error: e.message, publish_checklist: e.checklist }, status: :unprocessable_entity
        end

        def render_link_conflict(error)
          raise error unless PublicSlug.conflict?(error)

          render json: { errors: [Event.public_slug_taken_message] }, status: :unprocessable_entity
        end

        def set_event
          @event = find_organization_event(params[:id])
          return unless @event

          if action_name == "cancellation_refunds"
            allowed = [:manage_events, :view_finance].any? do |permission|
              OrganizationAuthorization.allowed?(user: current_user, organization: current_organization,
                permission: permission, event: @event)
            end
            render json: { error: "You do not have permission to perform this action" }, status: :forbidden unless allowed
          else
            permissions_for_action.each do |permission|
              return unless authorize_organization!(permission, event: @event)
            end
          end
        end

        def permissions_for_action
          case action_name
          when "show" then [:view_events]
          when "stats" then [:view_finance]
          when "cancel" then [:manage_events, :refund]
          when "retry_cancellation_refunds", "mark_cash_refunded" then [:refund]
          when "attendees" then
            @can_view_attendees = OrganizationAuthorization.allowed?(user: current_user,
              organization: current_organization, permission: :view_attendees, event: @event)
            [@can_view_attendees ? :view_attendees : :view_finance]
          when "update", "slug_availability", "retranslate" then [:edit_event_content]
          else [:manage_events]
          end
        end

        def event_params
          params.permit(
            :title, :slug, :description, :short_description, :cover_image_url,
            :venue_id, :venue_name, :venue_address, :venue_city,
            :starts_at, :ends_at, :doors_open_at, :timezone,
            :category, :age_restriction, :max_capacity,
            :recurrence_rule, :recurrence_end_date, :show_attendees,
            :fee_policy, :buyer_fee_percent, :transfers_enabled, supported_locales: [],
            localized_content: AppLocale::ORGANIZER_CONTENT_LOCALES.index_with { Event::CONTENT_FIELDS },
            page_customization: {}
          )
        end

        def parsed_event_params
          attributes = event_params.to_h
          # An empty link field keeps the current link instead of clearing it.
          attributes.delete("slug") if attributes.key?("slug") && attributes["slug"].blank?
          timezone = attributes["timezone"].presence || @event&.timezone || "Pacific/Guam"
          %w[starts_at ends_at doors_open_at].each do |key|
            attributes[key] = EventTimeParser.call(attributes[key], timezone: timezone) if attributes.key?(key)
          end
          attributes
        rescue EventTimeParser::ParseError => e
          raise ActionController::BadRequest, e.message
        end

        def reschedule?(attributes)
          return false unless @event.published? || @event.postponed?

          %w[starts_at ends_at doors_open_at].any? do |attribute|
            attributes.key?(attribute) && @event.public_send(attribute) != attributes[attribute]
          end
        end

        def event_change_snapshot(event)
          {
            status: event.status,
            publicly_visible: event.publicly_visible?,
            starts_at: event.starts_at&.iso8601,
            ends_at: event.ends_at&.iso8601,
            doors_open_at: event.doors_open_at&.iso8601,
            venue_name: event.venue_name,
            venue_address: event.venue_address
          }
        end

        def clone_event(source, overrides = {})
          attrs = source.attributes.slice(
            "title", "description", "short_description", "cover_image_url", "page_customization",
            "venue_name", "venue_address", "venue_city", "timezone",
            "category", "age_restriction", "max_capacity",
            "show_attendees"
          ).merge(
            "organizer_profile_id" => source.organizer_profile_id,
            "organization_id" => source.organization_id,
            "status" => "draft",
            "slug" => nil,
            "published_at" => nil
          ).merge(overrides.stringify_keys)

          new_event = Event.new(attrs)
          new_event.audit_clone_source = source
          if new_event.save
            source.ticket_types.each do |tt|
              cloned_ticket_type = new_event.ticket_types.create!(
                name: tt.name,
                description: tt.description,
                price_cents: tt.price_cents,
                quantity_available: tt.quantity_available,
                door_allocation: tt.door_allocation,
                quantity_sold: 0,
                max_per_order: tt.max_per_order,
                max_per_buyer: tt.max_per_buyer,
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

        # A copy would not carry the hold, so it could be published and sold.
        def render_policy_hold_refusal(verb)
          render json: { error: "HåfaPass has placed a policy hold on this event, so it cannot be #{verb}. " \
            "Contact HåfaPass support to resolve the hold first." }, status: :unprocessable_entity
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
            organization_id: event.organization_id,
            organization_name: event.organization&.name,
            permissions: @event_permission_maps&.fetch(event.id) || OrganizationAuthorization.permissions_for(
              user: current_user, organization: current_organization, event: event
            ),
            title: event.title,
            slug: event.slug,
            custom_slug: event.custom_slug,
            slug_follows_title: event.slug_follows_title?,
            ever_published: event.ever_published?,
            description: event.description,
            short_description: event.short_description,
            cover_image_url: event.cover_image_url,
            page_customization: event.page_customization,
            image_asset_host: S3Service.public_asset_host,
            seller: SellerIdentity.for_event(event, platform_name: listing_settings.platform_name).as_json,
            service_fee_includes_processing: listing_settings.platform_bears_processing?,
            venue_name: event.venue_name,
            venue_address: event.venue_address,
            venue_city: event.venue_city,
            venue_id: event.venue_id,
            starts_at: event.starts_at,
            ends_at: event.ends_at,
            doors_open_at: event.doors_open_at,
            timezone: event.timezone,
            status: event.status,
            publicly_visible: event.publicly_visible?,
            organizer_verification_status: event.organizer_profile.verification_status,
            policy_hold_scope: event.policy_hold_scope,
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
            fee_policy: event.fee_policy,
            buyer_fee_percent: event.buyer_fee_percent,
            transfers_enabled: event.transfers_available?,
            assigned_seating: event.assigned_seating?,
            policy_hold: event.policy_hold_summary,
            sales_status: event.sales_status(context: (@sales_context ||= Event.sales_context)),
            supported_locales: event.supported_locales,
            localized_content: event.localized_content,
            translation_status: event.translation_status,
            automatic_translation_available: GtTranslationService.enabled?,
            localized_content_stale: event.stale_localized_content,
            created_at: event.created_at,
            updated_at: event.updated_at
          }

          json[:publish_checklist] = event.publish_checklist(organizer_agreement: listing_organizer_agreement)
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
            ticket_types = event.ticket_types.loaded? ? event.ticket_types.sort_by { |type| [type.sort_order || 0, type.id] } :
              event.ticket_types.order(:sort_order, :id)
            json[:ticket_types] = ticket_types.map do |tt|
              price = tt.current_price_cents
              fee = Commerce::ServiceFee.for_event(event, price, terms: listing_fee_terms)
              {
                id: tt.id,
                name: tt.name,
                description: tt.description,
                price_cents: tt.price_cents,
                current_price_cents: price,
                all_in_price_cents: fee.all_in_price_cents,
                service_fee_cents: fee.buyer_fee_cents,
                regular_all_in_price_cents: Commerce::ServiceFee.for_event(event, tt.price_cents, terms: listing_fee_terms).all_in_price_cents,
                quantity_remaining: tt.available_quantity,
                on_sale: tt.on_sale?,
                quantity_available: tt.quantity_available,
                quantity_sold: tt.quantity_sold,
                door_allocation: tt.door_allocation,
                door_sold_quantity: tt.door_sold_quantity,
                door_held_quantity: tt.door_held_quantity,
                door_available_quantity: tt.door_available_quantity,
                max_per_order: tt.max_per_order,
                max_per_buyer: tt.max_per_buyer,
                sales_start_at: tt.sales_start_at,
                sales_end_at: tt.sales_end_at
              }
            end
          end

          json
        end

        def listing_settings
          @listing_settings ||= SiteSetting.instance
        end

        def listing_fee_terms
          @listing_fee_terms ||= Commerce::ServiceFee.terms(listing_settings)
        end

        def listing_organizer_agreement
          @listing_organizer_agreement ||= PolicyRegistry.organizer_agreement
        end
      end
    end
  end
end
