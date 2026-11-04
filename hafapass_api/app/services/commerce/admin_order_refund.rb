# frozen_string_literal: true

module Commerce
  # An administrator's refund decision on a card order: the whole remaining
  # balance (cancels every unadmitted ticket), selected tickets (cancels those,
  # including ones transferred to someone else), or a set amount (tickets stay
  # valid). This is the path behind "Contact HåfaPass support" once an event has
  # paid out; the refund then lowers the organizer's balance and any shortfall
  # shows as a negative balance they owe. Every request is audited with its note.
  class AdminOrderRefund
    class Error < StandardError
      attr_reader :outcome

      def initialize(message, outcome: {})
        super(message)
        @outcome = outcome
      end
    end

    REASON = "requested_by_customer"
    MAX_NOTE_LENGTH = 2000

    def self.call(**)
      new(**).call
    end

    # What the refund dialog needs, read fresh each time it opens.
    def self.options(order)
      captured = captured_payments(order)
      payment = captured.first if captured.one?
      {
        order_id: order.id,
        currency: order.currency,
        refundable_cents: payment ? RefundCreator.remaining_cents(order: order, payment: payment) : 0,
        event_paid_out: order.event.paid_out_to_organizer?,
        organization_name: order.event.organization&.name,
        unavailable_reason: unavailable_reason(order, captured),
        tickets: order.tickets.includes(:ticket_type, :order_item).order(:id).map { |ticket| ticket_option(order, ticket) }
      }.compact
    end

    def self.captured_payments(order)
      order.payments.where(status: [:succeeded, :partially_refunded]).order(:id).to_a
    end
    private_class_method :captured_payments

    def self.unavailable_reason(order, captured)
      return "Only completed or partially refunded orders can be refunded here." unless order.completed? || order.partially_refunded?
      return "This order has no captured card payment to refund." if captured.empty?
      return "This order has several captured payments. Resolve it in Refund issues." if captured.many?
      return "Only Stripe card payments can be refunded here." unless captured.first.provider == "stripe"
      return "This order needs finance review first. Resolve it in Refund issues." if RefundSafety.finance_review_required?(order)

      nil
    end
    private_class_method :unavailable_reason

    def self.ticket_option(order, ticket)
      blocked = if ticket.checked_in? then "Already scanned"
      elsif !ticket.issued? then "Not active"
      elsif RefundTicket.active.exists?(ticket_id: ticket.id) then "Already has a refund"
      elsif ticket.refundable_cents <= 0 then "Nothing to refund"
      end
      {
        id: ticket.id,
        ticket_type: ticket.ticket_type&.name,
        attendee_name: ticket.attendee_name,
        refundable_cents: ticket.refundable_cents,
        transferred: ticket.transferred_away_from?(order),
        unavailable_reason: blocked
      }.compact
    end
    private_class_method :ticket_option

    def initialize(order:, actor:, note:, idempotency_key:, amount_cents: nil, ticket_ids: nil, request: nil)
      @order = order
      @actor = actor
      @note = note.to_s.strip
      @raw_key = idempotency_key.to_s.strip
      @raw_amount = amount_cents
      @raw_ticket_ids = ticket_ids
      @request = request
    end

    def call
      validate!
      amount = parsed_amount
      tickets = selected_tickets
      paid_out = order.event.paid_out_to_organizer?

      AuditLogger.record!(action: "order.admin_refund_requested", auditable: order, actor: @actor,
        organization: order.event.organization, event: order.event, source: "admin", outcome: "requested",
        deduplication_key: "admin-order-refund:#{refund_key}",
        metadata: { note: @note, amount_cents: amount, ticket_ids: tickets&.map(&:id), event_paid_out: paid_out }.compact,
        request: @request)
      refund = RefundCreator.call(order: order, amount_cents: amount, tickets: tickets, reason: REASON,
        requested_by: @actor, idempotency_key: refund_key, admin_initiated: true)
      raise fail_with("The refund failed. Check Refund issues before trying again.") if refund.failed? || refund.cancelled?

      refund
    rescue RefundCreator::RefundError => e
      raise fail_with(e.message)
    end

    private

    attr_reader :order

    def validate!
      raise fail_with("Only administrators can issue this refund") unless @actor&.admin?
      raise fail_with("Add a note explaining the refund") if @note.blank?
      raise fail_with("Note is too long") if @note.length > MAX_NOTE_LENGTH
      raise fail_with("Idempotency-Key header is required") if @raw_key.blank?
      raise fail_with("Choose an amount or tickets, not both") if @raw_amount.present? && @raw_ticket_ids.present?
    end

    def parsed_amount
      return if @raw_amount.blank?
      return @raw_amount if @raw_amount.is_a?(Integer) && @raw_amount.positive?
      return @raw_amount.to_i if @raw_amount.is_a?(String) && @raw_amount.match?(/\A[1-9]\d{0,8}\z/)

      raise fail_with("Refund amount must be a positive number of cents")
    end

    def selected_tickets
      return if @raw_ticket_ids.blank?

      ids = Array(@raw_ticket_ids).map(&:to_s).uniq
      raise fail_with("Ticket not found for this order") unless ids.all? { |id| id.match?(/\A\d{1,18}\z/) }

      found = order.tickets.where(id: ids).to_a
      raise fail_with("Ticket not found for this order") unless found.length == ids.length

      found
    end

    def refund_key
      "admin-refund:#{order.id}:#{@raw_key}"
    end

    def fail_with(message)
      Error.new(message, outcome: RefundOutcome.call(order: order, idempotency_key: refund_key))
    end
  end
end
