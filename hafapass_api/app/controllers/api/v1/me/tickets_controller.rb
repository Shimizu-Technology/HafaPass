class Api::V1::Me::TicketsController < ApplicationController
  include Paginatable

  def index
    now = Time.current
    tickets = Ticket
      .where(holder_user: current_user)
      .includes(:event, :order, :ticket_transfers, :parent_ticket, ticket_type: :included_events)
      .order(created_at: :desc)

    if %w[upcoming past].include?(params[:tab])
      effective_end_sql = <<~SQL.squish
        GREATEST(
          COALESCE(events.ends_at, events.starts_at),
          COALESCE((
            SELECT MAX(COALESCE(inc.ends_at, inc.starts_at))
            FROM ticket_type_included_events ttie
            INNER JOIN events inc ON inc.id = ttie.included_event_id
            WHERE ttie.ticket_type_id = tickets.ticket_type_id
              AND tickets.parent_ticket_id IS NULL
          ), COALESCE(events.ends_at, events.starts_at))
        )
      SQL
      tickets = tickets.joins(:event)
      tickets = if params[:tab] == "upcoming"
        tickets.where("#{effective_end_sql} > ?", now)
      else
        tickets.where("#{effective_end_sql} <= ? OR (#{effective_end_sql}) IS NULL", now)
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
    {
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
  end

  def effective_ends_at_for(ticket)
    candidates = [ticket.event.ends_at, ticket.event.starts_at].compact
    if ticket.pass_parent?
      ticket.ticket_type.included_events.each do |included_event|
        end_time = included_event.ends_at || included_event.starts_at
        candidates << end_time if end_time
      end
    end
    candidates.max
  end
end
