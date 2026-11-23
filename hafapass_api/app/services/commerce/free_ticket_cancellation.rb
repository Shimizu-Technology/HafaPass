# frozen_string_literal: true

module Commerce
  class FreeTicketCancellation
    ACTION = "order.free_tickets_cancelled"

    def self.call(**)
      new(**).call
    end

    def initialize(order:, tickets:, actor:, reason:, idempotency_key:)
      @order = order
      @ids = tickets.map(&:id).sort
      @actor = actor
      @reason = reason.presence || "organizer_free_ticket_cancellation"
      @key_prefix = "free-ticket-cancellation:#{order.id}:#{Digest::SHA256.hexdigest(idempotency_key)}:"
      @audit_key = @key_prefix + Digest::SHA256.hexdigest(@ids.join(","))
    end

    def call
      audit = nil
      changed = false
      Order.transaction do
        @actor.lock!("FOR NO KEY UPDATE")
        @order.event.organization.lock!("FOR NO KEY UPDATE")
        @order.event.lock!
        @order.lock!
        # Request identity is stored in the immutable audit key so replay
        # still works if identifying details in the audit payload are redacted.
        audit = AuditLog.where(action: ACTION).where("deduplication_key LIKE ?", "#{@key_prefix}%").first
        if audit
          refuse!("Idempotency-Key was already used for a different cancellation") if audit.deduplication_key != @audit_key
        else
          audit = cancel!
          changed = true
        end
      end
      @order.event.notify_waitlist_if_available if changed
      {
        id: audit.id, order_id: @order.id, currency: @order.currency, status: "succeeded",
        amount_cents: 0, refunded_total_cents: 0, remaining_cents: 0, items: [],
        free_ticket_cancellation: true, ticket_ids: @ids, order_status: @order.buyer_status,
        succeeded_at: audit.occurred_at
      }
    end

    private

    def cancel!
      refuse!("Only active free orders can be cancelled") unless @order.total_cents.zero? && @order.completed?
      refuse!(RefundCreator::FREE_PAID_OUT_MESSAGE) if @order.event.paid_out_to_organizer?
      if @order.ticket_access_blocked? || RefundSafety.finance_review_required?(@order)
        refuse!("Contact support to review this order before continuing.")
      end

      group = @order.tickets.where(id: @ids).or(@order.tickets.where(parent_ticket_id: @ids))
        .order(:id).lock.to_a
      selected = group.select { |ticket| @ids.include?(ticket.id) }
      refuse!("Ticket not found for this order") unless selected.size == @ids.size

      children = group.select(&:pass_child?).group_by(&:parent_ticket_id)
      selected.each do |ticket|
        amount = ticket.refundable_cents
        refuse!("Only free tickets can be cancelled here") unless amount.zero?
        blocked = OrganizerRefundOptions.ticket_unavailable_reason(@order, ticket,
          children: children.fetch(ticket.id, []), refund_pending: ticket.refund_pending?, amount: amount)
        refuse!(blocked) if blocked
      end

      before_status = @order.status
      group.reject(&:cancelled?).each { |ticket| ticket.cancel_unused_and_release_inventory!(reason: @reason) }
      @order.update!(status: :cancelled) unless @order.tickets.where.not(status: :cancelled).exists?
      AuditLogger.record!(action: ACTION, auditable: @order, actor: @actor,
        deduplication_key: @audit_key, before_data: { status: before_status }, after_data: { status: @order.status },
        metadata: { ticket_ids: @ids, ticket_count: @ids.size, reason: @reason })
    end

    def refuse!(message)
      raise RefundCreator::RefundError, message
    end
  end
end
