class Api::V1::Me::TicketsController < ApplicationController
  include Paginatable

  def index
    now = Time.current
    owned_parent_ids = Ticket.where(holder_user: current_user, parent_ticket_id: nil).select(:id)
    tickets = Ticket
      .where(holder_user: current_user)
      .where("tickets.parent_ticket_id IS NULL OR tickets.parent_ticket_id NOT IN (?)", owned_parent_ids)
      .preload(
        :event, :order, :ticket_transfers,
        :inventory_retention, :pending_refund_tickets,
        ticket_type: :included_events,
        parent_ticket: [:pending_refund_tickets, :inventory_retention],
        child_tickets: [
          :event, :order, :ticket_type, :inventory_retention, :pending_refund_tickets,
          { parent_ticket: [:pending_refund_tickets, :inventory_retention] }
        ]
      )
      .order(created_at: :desc, id: :desc)

    if %w[upcoming past].include?(params[:tab])
      ineligible_statuses = Event.statuses.values_at(*Event::INELIGIBLE_PASS_NIGHT_STATUSES)
      included_max_sql = <<~SQL.squish
        (
          SELECT MAX(COALESCE(inc.ends_at, inc.starts_at))
          FROM ticket_type_included_events ttie
          INNER JOIN events inc ON inc.id = ttie.included_event_id
          WHERE ttie.ticket_type_id = tickets.ticket_type_id
            AND inc.status NOT IN (:ineligible_statuses)
        )
      SQL
      has_included_sql = <<~SQL.squish
        EXISTS (
          SELECT 1
          FROM ticket_type_included_events ttie_any
          WHERE ttie_any.ticket_type_id = tickets.ticket_type_id
        )
      SQL
      effective_end_sql = <<~SQL.squish
        CASE
          WHEN tickets.parent_ticket_id IS NULL AND #{included_max_sql} IS NOT NULL
            THEN GREATEST(events.starts_at, #{included_max_sql})
          WHEN tickets.parent_ticket_id IS NULL AND #{has_included_sql}
            THEN COALESCE(events.starts_at, events.ends_at)
          ELSE COALESCE(events.ends_at, events.starts_at)
        END
      SQL
      tickets = tickets.joins(:event)
      tickets = if params[:tab] == "upcoming"
        tickets.where("(#{effective_end_sql}) > :now", ineligible_statuses: ineligible_statuses, now: now)
      else
        tickets.where("(#{effective_end_sql}) <= :now OR (#{effective_end_sql}) IS NULL",
          ineligible_statuses: ineligible_statuses, now: now)
      end
    end

    pagy, paginated_tickets = paginate(tickets)

    render json: {
      tickets: paginated_tickets.map { |ticket| ticket_json(ticket, now: now) },
      meta: pagination_meta(pagy)
    }
  end

  private

  def ticket_json(ticket, now: Time.current)
    anchored_ends_at = effective_ends_at_for(ticket)
    json = {
      id: ticket.id,
      display_credential: ticket.display_credential,
      status: ticket.status,
      attendee_name: ticket.attendee_name,
      checked_in_at: ticket.checked_in_at,
      admission_allowed: ticket.admission_allowed?,
      is_pass: ticket.pass_parent?,
      parent_ticket_id: ticket.parent_ticket_id,
      upcoming: anchored_ends_at.present? && anchored_ends_at > now,
      pending_transfer: ticket.issued? ? ticket.pending_transfer_summary : nil,
      event: {
        id: ticket.event.id,
        title: ticket.event.title,
        slug: ticket.event.slug,
        status: ticket.event.status,
        venue_name: ticket.event.venue_name,
        starts_at: ticket.event.starts_at,
        ends_at: ticket.pass_parent? ? (anchored_ends_at || ticket.event.ends_at) : ticket.event.ends_at,
        timezone: ticket.event.timezone,
        transfers_enabled: ticket.event.transfers_available?,
        cover_image_url: ticket.event.cover_image_url,
        image_asset_host: S3Service.public_asset_host
      },
      ticket_type: {
        id: ticket.ticket_type.id,
        name: ticket.ticket_type.name,
        price_cents: ticket.ticket_type.price_cents
      },
      order_id: ticket.order_id
    }

    if ticket.pass_parent?
      owned_children = ticket.child_tickets.select { |child| child.holder_user_id == current_user.id }
      sorted_children = Passes::TicketPayload.sort_children(owned_children)
      json.merge!(
        is_pass: true,
        pass_parent: true,
        pass_child: false,
        pass_nights_count: sorted_children.size,
        child_tickets: sorted_children.map { |child|
          Passes::TicketPayload.child_json(child, expose_credential: true)
        }
      )
    end

    json
  end

  def effective_ends_at_for(ticket)
    if ticket.pass_parent?
      included_max = ticket.ticket_type.included_events
        .select(&:eligible_pass_night?)
        .filter_map { |included_event| included_event.ends_at || included_event.starts_at }
        .max
      return [ticket.event.starts_at, included_max].compact.max if included_max
      return ticket.event.starts_at || ticket.event.ends_at if ticket.ticket_type.included_events.any?
    end

    [ticket.event.ends_at, ticket.event.starts_at].compact.max
  end
end
