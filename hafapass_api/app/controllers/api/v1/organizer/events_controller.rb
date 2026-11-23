module Api
  module V1
    module Organizer
      class EventsController < BaseController
        include CancellationRefundActions
        include Paginatable

        before_action :set_event, only: [
          :show, :update, :destroy, :publish, :postpone, :resume, :cancel, :complete, :archive,
          :clone, :bulk_clone, :generate_recurrences, :stats, :attendees, :slug_availability, :retranslate,
          :cancellation_refunds, :retry_cancellation_refunds, :mark_cash_refunded,
          :preview_link, :rotate_preview_link
        ]

        def index
          events = OrganizationAuthorization.accessible_events(user: current_user, organization: current_organization)
            .includes(:organization, :organizer_profile, :event_seating_configuration, :pass_inclusions,
              ticket_types: [:waitlist_offers, { ticket_type_included_events: :included_event },
                { pricing_tiers: [:inventory_holds, :waitlist_offers,
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
          pass_included_ids = paginated_events.select { |ev| ev.pass_inclusions.any? }.map(&:id)
          @pass_committed_by_event_id = EventCapacity.pass_committed_by_event_ids(pass_included_ids)
          archived_pass_night_ids = paginated_events.flat_map do |ev|
            ev.preloaded_pass_included_events.to_a.select(&:archived?).map(&:id)
          end.uniq
          @sales_context = Event.sales_context.merge(
            archive_from_statuses: Event.latest_archive_from_statuses_by_event_id(archived_pass_night_ids)
          )
          render json: {
            events: paginated_events.map { |event| event_json(event, include_ticket_types: true) },
            meta: pagination_meta(pagy)
          }
        end

        def show
          json = event_json(@event, include_ticket_types: true)
          if json[:permissions][:manage_inventory]
            json[:scanner_questions] = @event.registration_questions.where(show_on_scanner: true).order(:position, :id).map do |question|
              question.as_json(only: %i[id prompt kind scope position options ticket_type_ids validation_rules show_on_scanner])
            end
          end
          render json: json
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
          # on the home summary through show night (or through the latest live
          # included night for a multi-night pass).
          upcoming = events.published.effectively_ending_after(Time.current)
          next_event = upcoming.order(:starts_at, :id).first
          json = {
            upcoming_events_count: upcoming.count,
            tickets_sold: Ticket.where(event_id: events.select(:id), parent_ticket_id: nil).where.not(status: :cancelled).count,
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
          @event.with_lock("FOR NO KEY UPDATE") do
            @event.ticket_types.order(:id).lock.load
            attributes = parsed_event_params
            can_manage = OrganizationAuthorization.allowed?(
              user: current_user, organization: current_organization, permission: :manage_events, event: @event
            )
            unless can_manage
              attributes.slice!("title", "slug", "description", "short_description", "cover_image_url", "category", "page_customization")
            end
            attributes["transfers_enabled"] = false if can_manage && !LaunchCapabilities.enabled?(:ticket_transfers)
            change_type = buyer_visible_change(attributes)
            change_reason = params[:change_reason].to_s.strip.presence
            if change_type && change_reason.blank?
              return render json: { error: "A reason is required when changing the schedule or venue of a published or postponed event" },
                status: :unprocessable_entity
            end

            before_data = event_change_snapshot(@event) if change_type
            previous_design = @event.page_customization.deep_dup if attributes.key?("page_customization")
            updated = @event.update(attributes)
            if updated && previous_design && previous_design != @event.page_customization
              AuditLogger.record!(action: "event.page_customized", auditable: @event, actor: current_user,
                before_data: { page_customization: previous_design },
                after_data: { page_customization: @event.page_customization }, request: request)
            end
            if updated && change_type
              event_change = @event.event_changes.create!(
                actor_user: current_user,
                change_type: change_type,
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
          return unless authorize_organization!(:manage_events)

          return render_policy_hold_refusal("copied") if @event.policy_hold?

          cloned = clone_event(@event, title: "#{@event.title} (Copy)", starts_at: nil, ends_at: nil, doors_open_at: nil)
          if cloned.persisted?
            render json: event_json(cloned, include_ticket_types: true), status: :created
          else
            render json: { errors: cloned.errors.full_messages }, status: :unprocessable_entity
          end
        end

        MAX_BULK_CLONE_OCCURRENCES = 25

        def bulk_clone
          return unless authorize_organization!(:manage_events)
          return render_policy_hold_refusal("copied") if @event.policy_hold?

          raw_occurrences = params[:occurrences]
          unless raw_occurrences.is_a?(Array) && raw_occurrences.any?
            return render json: { error: "occurrences must be a non-empty array" }, status: :unprocessable_entity
          end
          if raw_occurrences.size > MAX_BULK_CLONE_OCCURRENCES
            return render json: { error: "Cannot bulk clone more than #{MAX_BULK_CLONE_OCCURRENCES} occurrences at once" },
              status: :unprocessable_entity
          end

          series = nil
          if params[:event_series_id].present?
            series = current_organization.event_series.find_by(id: params[:event_series_id])
            return render json: { error: "Event series not found" }, status: :not_found unless series
          end

          series_role = params[:series_role].presence || "regular_night"
          unless EventSeriesMembership.roles.key?(series_role.to_s)
            return render json: { error: "Invalid series_role" }, status: :unprocessable_entity
          end

          timezone = @event.timezone.presence || "Pacific/Guam"
          parsed_occurrences = []
          raw_occurrences.each_with_index do |occ, index|
            unless occ.is_a?(ActionController::Parameters) || occ.is_a?(Hash)
              return render json: { error: "Occurrence #{index + 1} must be an object" }, status: :unprocessable_entity
            end
            occ_hash = occ.respond_to?(:to_unsafe_h) ? occ.to_unsafe_h : occ.to_h
            occ_hash = occ_hash.stringify_keys
            parsed_occurrences << {
              title: occ_hash["title"],
              starts_at: EventTimeParser.call(occ_hash["starts_at"], timezone: timezone),
              ends_at: EventTimeParser.call(occ_hash["ends_at"], timezone: timezone),
              doors_open_at: occ_hash["doors_open_at"].present? ? EventTimeParser.call(occ_hash["doors_open_at"], timezone: timezone) : nil
            }
          rescue EventTimeParser::ParseError => e
            return render json: { error: "Occurrence #{index + 1}: #{e.message}" }, status: :unprocessable_entity
          end

          created = []
          validation_errors = []

          Event.transaction do
            next_position = series ? ((series.event_series_memberships.maximum(:position) || -1) + 1) : 0
            parsed_occurrences.each_with_index do |occ, index|
              cloned = clone_event(@event, occ)
              unless cloned.persisted?
                validation_errors << "Occurrence #{index + 1}: #{cloned.errors.full_messages.join(', ')}"
                raise ActiveRecord::Rollback
              end

              if series
                membership = series.event_series_memberships.build(
                  event: cloned,
                  role: series_role,
                  position: next_position
                )
                unless membership.save
                  validation_errors << "Occurrence #{index + 1}: #{membership.errors.full_messages.join(', ')}"
                  raise ActiveRecord::Rollback
                end
                next_position += 1
              end

              created << cloned
            end
          end

          if validation_errors.any?
            return render json: { error: validation_errors.first, errors: validation_errors },
              status: :unprocessable_entity
          end

          render json: {
            created_count: created.size,
            events: created.map { |e| event_json(e, include_ticket_types: true) }
          }, status: :created
        rescue ActiveRecord::RecordNotUnique => e
          if PublicSlug.conflict?(e)
            render_link_conflict(e)
          else
            render json: { error: "Duplicate event or series membership conflict" }, status: :unprocessable_entity
          end
        rescue ActiveRecord::RecordInvalid => e
          render json: { error: e.record.errors.full_messages.first, errors: e.record.errors.full_messages },
            status: :unprocessable_entity
        end

        def generate_recurrences
          return unless authorize_organization!(:manage_events)

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

          total_tickets_sold = tickets.where(parent_ticket_id: nil).where.not(status: :cancelled).count
          total_revenue_cents = financials[:net_cents]
          tickets_checked_in = tickets.where(status: :checked_in).count

          tickets_by_type = @event.ticket_types.order(:sort_order, :id).map do |tt|
            type_tickets = tickets.where(ticket_type_id: tt.id, parent_ticket_id: nil).where.not(status: :cancelled)
            {
              name: tt.name,
              sold: type_tickets.count,
              available: tt.available_quantity,
              revenue_cents: ticket_type_net_revenue(tt, orders)
            }
          end

          pass_tickets = pass_tickets_summary(tickets)

          recent_orders = orders.order(created_at: :desc).limit(10).map do |order|
            {
              id: order.id,
              buyer_name: order.buyer_name,
              buyer_email: order.buyer_email,
              ticket_count: order.tickets.where(parent_ticket_id: nil).count,
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
            pass_tickets: pass_tickets,
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

        def pass_tickets_summary(tickets)
          payment_mode = SiteSetting.instance.payment_mode
          children = tickets.where.not(parent_ticket_id: nil)
            .includes(:ticket_type, :inventory_retention, :pending_refund_tickets,
              { parent_ticket: [:pending_refund_tickets, :inventory_retention] }, { order: [:disputes, :refunds, :payments] })
            .to_a
          by_type = children.group_by(&:ticket_type)
            .sort_by { |tt, _| [tt.sort_order || 0, tt.id] }
            .map do |tt, type_children|
              {
                name: tt.name,
                eligible: type_children.count { |t| pass_child_eligible?(t, payment_mode: payment_mode) },
                checked_in: type_children.count(&:checked_in?),
                revenue_cents: 0
              }
            end
          {
            eligible: children.count { |t| pass_child_eligible?(t, payment_mode: payment_mode) },
            checked_in: children.count(&:checked_in?),
            by_type: by_type
          }
        end

        def pass_child_eligible?(ticket, payment_mode:)
          !ticket.cancelled? && !ticket.transferred? && !ticket.inventory_retained? &&
            !ticket.parent_ticket&.inventory_retained? && !ticket.parent_ticket&.cancelled? &&
            !ticket.order.ticket_access_blocked? && !ticket.refund_pending? &&
            ticket.order.ticket_fulfilled?(payment_mode: payment_mode)
        end

        def attendees
          active_only = params[:active_only] == "true"
          return unless !active_only || @can_view_attendees || authorize_organization!(:view_attendees, event: @event)

          query = OrganizerSalesQuery.new(event: @event, params: params, attendee_access: @can_view_attendees, active_only: active_only)
          pagy, records = paginate(query.relation, items: params.fetch(:per_page, 25).to_i.clamp(1, 100))
          can_view_finance = OrganizationAuthorization.allowed?(user: current_user, organization: current_organization,
            permission: :view_finance, event: @event)
          records = records.includes(*attendee_preloads(query.view)).to_a
          answers = EventReportRegistrations::Inline.new(records) if @can_view_attendees
          rows = records.map do |record|
            if record.is_a?(Order)
              attendee_order_row(record, can_view_finance, answers)
            else
              attendee_ticket_row(record, answers)
            end
          end
          payload = { attendees: rows, meta: pagination_meta(pagy) }
          if active_only
            questions = EventReportRegistrations.new(event: @event, tickets: query.relation).questions
            payload[:registration_questions] = questions.map { |question| { question_id: question.id, prompt: question.prompt, kind: question.kind } }
          end
          response.headers["Cache-Control"] = "no-store"
          render json: payload
        rescue OrganizerSalesQuery::InvalidFilter => error
          render json: { error: error.message }, status: :unprocessable_entity
        end

        private

        def attendee_preloads(view)
          if view == "orders"
            [{ tickets: :ticket_type }]
          else
            [:ticket_type, { order: :payments }, *(@can_view_attendees ? [:pricing_tier, :order_item] : [])]
          end
        end

        def attendee_order_row(order, can_view_finance, answers)
          row = { id: order.id, order_number: order.reference,
            ticket_type: order.tickets.map { |ticket| ticket.ticket_type.name }.uniq.join(", "),
            status: order.status, sales_status_label: OrganizerTicketSalesStatus.label(order.status),
            purchase_date: order.completed_at || order.created_at, channel: FinanceExports.channel(order),
            ticket_count: order.tickets.size, checked_in_count: order.tickets.count(&:checked_in?) }
          if @can_view_attendees
            row.merge!(attendee_name: order.buyer_name, attendee_email: order.buyer_email,
              checked_in_at: order.tickets.filter_map(&:checked_in_at).max,
              registration_answers: answers.for_order(order))
          end
          row[:amount_cents] = order.total_cents if can_view_finance
          row
        end

        def attendee_ticket_row(ticket, answers)
          order = ticket.order
          sales_status = OrganizerTicketSalesStatus.for(ticket, event_cancelled: @event.cancelled?)
          row = { id: ticket.id, ticket_type: ticket.ticket_type.name, status: ticket.status, sales_status: sales_status,
            sales_status_label: OrganizerTicketSalesStatus.label(sales_status), order_id: order.id, order_number: order.reference,
            purchase_date: order.completed_at || order.created_at, channel: FinanceExports.channel(order), test_payment: order.test_payment? }
          if @can_view_attendees
            row.merge!(attendee_name: ticket.attendee_name, attendee_email: ticket.holder_email.presence || ticket.attendee_email,
              buyer_name: order.buyer_name, checked_in_at: ticket.checked_in_at,
              pricing_tier: ticket.order_item&.tier_name.presence || ticket.pricing_tier&.name,
              order_status_label: OrganizerTicketSalesStatus.label(order.status),
              registration_answers: answers.for_ticket(ticket))
          end
          row
        end

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

        # Buyers hear about schedule and venue edits to a published or
        # postponed event. A schedule edit (which may also move the venue) is
        # "rescheduled"; a venue-only edit is "venue_changed".
        def buyer_visible_change(attributes)
          return unless @event.published? || @event.postponed?
          return "rescheduled" if schedule_change?(attributes)

          "venue_changed" if venue_change?(attributes)
        end

        def schedule_change?(attributes)
          %w[starts_at ends_at doors_open_at].any? do |attribute|
            attributes.key?(attribute) && @event.public_send(attribute) != attributes[attribute]
          end
        end

        # Compare what buyers see. Choosing a saved venue copies its details
        # (Event#copy_venue_details), so a venue ID alone is not a change.
        def venue_change?(attributes)
          return false unless (attributes.keys & %w[venue_id venue_name venue_address venue_city]).any?

          venue = Venue.find_by(id: attributes["venue_id"]) if attributes["venue_id"].present? &&
            attributes["venue_id"].to_s != @event.venue_id.to_s
          proposed = if venue
            [venue.name, venue.address, venue.village]
          else
            %w[venue_name venue_address venue_city].map { |key| attributes.fetch(key, @event.public_send(key)) }
          end
          current = [@event.venue_name, @event.venue_address, @event.venue_city]
          proposed.map { |value| value.to_s.strip } != current.map { |value| value.to_s.strip }
        end

        def event_change_snapshot(event)
          {
            status: event.status,
            publicly_visible: event.publicly_visible?,
            starts_at: event.starts_at&.iso8601,
            ends_at: event.ends_at&.iso8601,
            doors_open_at: event.doors_open_at&.iso8601,
            venue_name: event.venue_name,
            venue_address: event.venue_address,
            venue_city: event.venue_city
          }
        end

        def clone_event(source, overrides = {})
          attrs = source.attributes.slice(
            "title", "description", "short_description", "cover_image_url", "page_customization",
            "venue_id", "venue_name", "venue_address", "venue_city", "timezone",
            "category", "age_restriction", "max_capacity",
            "fee_policy", "buyer_fee_percent", "transfers_enabled",
            "show_attendees"
          ).merge(
            "organizer_profile_id" => source.organizer_profile_id,
            "organization_id" => source.organization_id,
            "status" => "draft",
            "slug" => nil,
            "published_at" => nil,
            "transfers_enabled" => LaunchCapabilities.enabled?(:ticket_transfers) ? source.transfers_enabled : false
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
                attendee_info_mode: tt.attendee_info_mode,
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
            can_create_events: OrganizationAuthorization.allowed?(user: current_user,
              organization: current_organization, permission: :manage_events),
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

          json[:publish_checklist] = event.publish_checklist(
            organizer_agreement: listing_organizer_agreement,
            pass_committed: @pass_committed_by_event_id ? @pass_committed_by_event_id.fetch(event.id, 0) : nil
          )
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
              event.ticket_types.includes(:pricing_tiers, ticket_type_included_events: :included_event).order(:sort_order, :id)
            json[:ticket_types] = ticket_types.map do |tt|
              price = tt.current_price_cents
              fee = Commerce::ServiceFee.for_event(event, price, terms: listing_fee_terms)
              sorted_links = tt.ticket_type_included_events.sort_by { |link| [link.position, link.id] }
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
                attendee_info_mode: tt.attendee_info_mode,
                door_check_mode: tt.door_check_mode,
                door_alert_label: tt.door_alert_label,
                door_instructions: tt.door_instructions,
                scanner_show_buyer: tt.scanner_show_buyer,
                sales_start_at: tt.sales_start_at,
                sales_end_at: tt.sales_end_at,
                is_pass: tt.is_pass?,
                included_event_ids: sorted_links.map(&:included_event_id),
                included_events: sorted_links.filter_map do |link|
                  link.included_event && Passes::TicketPayload.included_event_json(link.included_event)
                end
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
