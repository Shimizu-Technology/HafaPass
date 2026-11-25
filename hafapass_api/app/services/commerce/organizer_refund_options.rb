# frozen_string_literal: true

module Commerce
  class OrganizerRefundOptions
    def self.call(order)
      new(order).call
    end

    # Call again under the order and ticket locks when accepting a selection.
    def self.ticket_unavailable_reason(order, ticket, children:, refund_pending:, amount:)
      return "Already cancelled" if ticket.cancelled?
      return "Transferred to someone else" if ticket.transferred? || ticket.transferred_away_from?(order)
      return "A refund is already in progress" if refund_pending
      return "Already used" if ticket.checked_in?
      return "Choose the multi-night pass to cancel its nights" if ticket.pass_child?
      if ticket.pass_parent? && (ticket.previously_admitted? || children.any?(&:previously_admitted?))
        return "Pass already used on one or more nights" if order.total_cents.zero?

        return "Pass already used on one or more nights. Choose a custom amount to return money."
      end
      return "Already used" if ticket.previously_admitted?
      return "Already refunded" if RefundTicket.active.exists?(ticket_id: ticket.id)
      return "No money to refund for this ticket" if order.total_cents.positive? && amount.zero?

      nil
    end

    def initialize(order)
      @order = order
    end

    def call
      captured = order.payments.where(status: [:succeeded, :partially_refunded]).excluding_isolated_captures.order(:id).to_a
      payment = captured.first if captured.one?
      cash_order = order.payment_method == "door_cash" && payment&.provider == "door_cash"
      free_order = order.total_cents.zero?
      paid_out = order.event.paid_out_to_organizer?
      remaining = payment ? RefundCreator.remaining_cents(order: order, payment: payment) : 0
      blocked = unavailable_reason(captured, cash_order: cash_order, paid_out: paid_out, free_order: free_order, remaining: remaining)
      tickets = order.tickets.includes(:ticket_type, :order_item).order(:id).to_a
      children = tickets.select(&:pass_child?).group_by(&:parent_ticket_id)
      {
        order_id: order.id, currency: order.currency, refundable_cents: remaining,
        is_free_order: free_order, is_cash_order: cash_order, event_paid_out: paid_out,
        unavailable_reason: blocked,
        tickets: tickets.map { |ticket| ticket_option(ticket, children.fetch(ticket.id, []), blocked) }
      }
    end

    private

    attr_reader :order

    def unavailable_reason(captured, cash_order:, paid_out:, free_order:, remaining:)
      return "This order is no longer active." unless order.completed? || (!free_order && order.partially_refunded?)
      return RefundCreator::FREE_PAID_OUT_MESSAGE if paid_out && free_order
      return RefundCreator::PAID_OUT_MESSAGE if paid_out && !cash_order
      return RefundCreator::DISPUTE_MESSAGE if order.ticket_access_blocked?
      return "Contact support to review this order before continuing." if RefundSafety.finance_review_required?(order)
      return if free_order
      return "Contact support to review the payments on this order." unless captured.one?
      unless cash_order || (captured.first.provider == "stripe" && captured.first.provider_payment_id.present?)
        return "Contact support to return this payment."
      end
      return "There is no money left to refund on this order." unless remaining.positive?

      nil
    end

    def ticket_option(ticket, children, order_block)
      pending = ticket.refund_pending?
      amount = ticket.pass_child? ? 0 : ticket.refundable_cents
      blocked = self.class.ticket_unavailable_reason(order, ticket, children: children, refund_pending: pending, amount: amount)
      blocked ||= order_block
      {
        id: ticket.id, code: ticket.qr_code, status: ticket.status, checked_in: ticket.checked_in?,
        checked_in_at: ticket.checked_in_at, transferred: ticket.transferred? || ticket.transferred_away_from?(order),
        refund_pending: pending, refundable_cents: amount, ticket_type_name: ticket.ticket_type.name,
        attendee_name: ticket.attendee_name, is_pass_parent: ticket.pass_parent?,
        selectable: blocked.nil?, unavailable_reason: blocked
      }.tap do |option|
        option[:included_nights_count] = children.size if ticket.pass_parent?
      end
    end
  end
end
