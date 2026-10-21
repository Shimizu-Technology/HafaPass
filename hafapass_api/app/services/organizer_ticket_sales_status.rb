# frozen_string_literal: true

# One status precedence for the attendee screen, filters, and ticket CSV rows.
class OrganizerTicketSalesStatus
  LABELS = {
    "issued" => "Valid", "checked_in" => "Checked in", "refunded" => "Refunded",
    "partially_refunded" => "Partially refunded", "cancelled" => "Cancelled",
    "transferred" => "Transferred", "completed" => "Paid", "paid" => "Paid"
  }.freeze

  def self.label(status)
    LABELS.fetch(status.to_s) { status.to_s.humanize }
  end

  def self.for(ticket)
    return "cancelled" if ticket.cancelled? || ticket.order.cancelled?
    return ticket.order.status if ticket.order.refunded? || ticket.order.partially_refunded?

    ticket.status
  end

  def self.filter(relation, status)
    cancelled_ticket = Ticket.statuses.fetch("cancelled")
    cancelled_order = Order.statuses.fetch("cancelled")
    refund_orders = Order.statuses.values_at("refunded", "partially_refunded")
    case status
    when "paid"
      relation.where(orders: { status: Order.statuses.fetch("completed") })
        .where.not(tickets: { status: cancelled_ticket })
    when "cancelled"
      relation.where("tickets.status = ? OR orders.status = ?", cancelled_ticket, cancelled_order)
    when "refunded", "partially_refunded"
      relation.where(orders: { status: Order.statuses.fetch(status) })
        .where.not(tickets: { status: cancelled_ticket })
    else
      ticket_status = status == "not_checked_in" ? "issued" : status
      relation.where(tickets: { status: Ticket.statuses.fetch(ticket_status) })
        .where.not(orders: { status: [cancelled_order, *refund_orders] })
    end
  end
end
