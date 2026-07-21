# frozen_string_literal: true

class OrderPresenter
  def self.call(order, include_tickets: order.completed?, guest_access_token: nil)
    new(order, include_tickets: include_tickets, guest_access_token: guest_access_token).call
  end

  def initialize(order, include_tickets:, guest_access_token:)
    @order = order
    @include_tickets = include_tickets
    @guest_access_token = guest_access_token
  end

  def call
    {
      id: order.id,
      reference: order.reference,
      event_id: order.event_id,
      status: order.status,
      currency: order.currency,
      subtotal_cents: order.subtotal_cents,
      service_fee_cents: order.service_fee_cents,
      discount_cents: order.discount_cents,
      total_cents: order.total_cents,
      refunded_cents: order.refunded_cents,
      refundable_cents: order.refundable_cents,
      buyer_email: order.buyer_email,
      buyer_name: order.buyer_name,
      buyer_phone: order.buyer_phone,
      completed_at: order.completed_at,
      expires_at: order.expires_at,
      wallet_type: order.wallet_type,
      guest_access_token: guest_access_token,
      payment_status: latest_payment&.status,
      ticket_access_blocked: order.ticket_access_blocked?,
      promo_code: order.promo_code ? { id: order.promo_code.id, code: order.promo_code.code } : nil,
      event: event_json,
      latest_event_change: latest_event_change_json,
      order_items: ordered_order_items.map { |item| order_item_json(item) },
      tickets: include_tickets ? presented_tickets.map { |ticket| ticket_json(ticket) } : []
    }.compact
  end

  private

  attr_reader :order, :include_tickets, :guest_access_token

  def event_json
    event = order.event
    {
      id: event.id,
      title: event.title,
      slug: event.slug,
      status: event.status,
      venue_name: event.venue_name,
      venue_address: event.venue_address,
      starts_at: event.starts_at,
      ends_at: event.ends_at,
      doors_open_at: event.doors_open_at,
      timezone: event.timezone,
      transfers_enabled: event.transfers_enabled,
      assigned_seating: event.assigned_seating?,
      cover_image_url: event.cover_image_url
    }
  end

  def latest_event_change_json
    changes = order.event.event_changes
    change = if changes.loaded?
      changes.max_by { |candidate| [candidate.occurred_at || Time.at(0), candidate.id] }
    else
      changes.order(occurred_at: :desc, id: :desc).first
    end
    return unless change

    responses = change.event_change_responses
    response = if responses.loaded?
      responses.find { |candidate| candidate.order_id == order.id }
    else
      responses.find_by(order: order)
    end
    {
      id: change.id,
      change_type: change.change_type,
      reason: change.reason,
      before: change.before_data,
      after: change.after_data,
      occurred_at: change.occurred_at,
      response: response&.decision
    }
  end

  def order_item_json(item)
    {
      id: item.id,
      name: item.name,
      tier_name: item.tier_name,
      item_kind: item.item_kind,
      fulfillment_status: item.catalog_fulfillment&.status,
      unit_price_cents: item.unit_price_cents,
      quantity: item.quantity,
      subtotal_cents: item.subtotal_cents,
      discount_cents: item.discount_cents,
      fee_cents: item.fee_cents,
      tax_cents: item.tax_cents,
      organizer_proceeds_cents: item.organizer_proceeds_cents
    }
  end

  def ticket_json(ticket)
    transferred_away = ticket.holder_user_id.present? && ticket.holder_user_id != order.user_id
    {
      id: ticket.id,
      display_credential: transferred_away ? nil : ticket.display_credential,
      scan_credential: !transferred_away && ticket.admission_allowed? ? ticket.scan_credential : nil,
      status: transferred_away ? "transferred" : ticket.status,
      attendee_name: transferred_away ? nil : ticket.attendee_name,
      checked_in_at: ticket.checked_in_at,
      refundable_cents: !transferred_away && ticket.issued? ? ticket_refundable_amounts.fetch(ticket.id, 0) : 0,
      ticket_type: {
        id: ticket.ticket_type.id,
        name: ticket.ticket_type.name,
        price_cents: ticket.order_item&.unit_price_cents || ticket.ticket_type.price_cents
      },
      seat: seat_json(ticket)
    }
  end

  def seat_json(ticket)
    return unless ticket.event_seat

    seat = ticket.event_seat
    venue_seat = seat.venue_seat
    {
      id: seat.id,
      display_label: seat.display_label,
      section: venue_seat.seating_row.seating_section.name,
      row: venue_seat.seating_row.label,
      seat: venue_seat.label,
      accessibility_kind: venue_seat.accessibility_kind,
      obstructed_view: venue_seat.obstructed_view,
      view_note: venue_seat.view_note
    }
  end

  def latest_payment
    payments = order.payments
    return payments.max_by(&:id) if payments.loaded?

    payments.order(:id).last
  end

  def ordered_order_items
    items = order.order_items
    return items.sort_by(&:id) if items.loaded?

    items.order(:id).to_a
  end

  def presented_tickets
    @presented_tickets ||= begin
      tickets = order.tickets
      tickets = tickets.includes(:ticket_type, :order_item,
        event_seat: { venue_seat: { seating_row: :seating_section } }) unless tickets.loaded?
      tickets.to_a.sort_by(&:id)
    end
  end

  def ticket_refundable_amounts
    @ticket_refundable_amounts ||= presented_tickets.group_by(&:order_item).each_with_object({}) do |(item, tickets), amounts|
      next unless item

      ordered = tickets.sort_by(&:id)
      item_total = item.subtotal_cents + item.fee_cents + item.tax_cents - item.discount_cents
      allocations = Commerce::MoneyAllocator.call(item_total, Array.new(ordered.length, 1))
      ordered.each_with_index { |ticket, index| amounts[ticket.id] = allocations[index] }
    end
  end
end
