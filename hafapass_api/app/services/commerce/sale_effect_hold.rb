# frozen_string_literal: true

module Commerce
  # Keeps a provider refund or lost dispute from changing a sale that its
  # payment does not positively own (A1-R1 review finding 1; docs/design/
  # never-fulfilled-captures.md §6.7).
  #
  # The provider fact is always recorded: the refund succeeds, the dispute is
  # lost, the payment's own refund status changes. What waits is everything
  # that acts on the sale: refund items, the order's status and refund
  # total, commission reversal, ticket and inventory release, the buyer email
  # and, for a dispute, cancelling the order's tickets.
  #
  # A payment owns the sale when the database function
  # hafapass_sale_owner_payment says so (the same rule guards refund items,
  # commission reversals, dispute ticket cancellations and retained inventory
  # for every writer, old or new):
  #   - the order's recorded fulfilling payment;
  #   - an order-scope never-fulfilled capture (there is no sale to damage);
  #   - with no fulfilling payment recorded, the order's only captured
  #     payment, and for a fenced payment only when the order never fulfilled.
  #
  # Otherwise one never_fulfilled_sale_effects_held exception per movement
  # holds the event's payouts and finalization (an evidence hold: a note
  # cannot close it). release! replays the held effects exactly once when
  # ownership is later proven, or closes the hold without effect when the
  # payment is classified as a payment-scope capture (its return is posted
  # by classification).
  #
  # Locks: hold! runs inside the refund or dispute writer's organization ->
  # event -> order transaction. release! takes the same prefix itself. A
  # capture-side boundary (lifecycle event -> order) only enqueues the job.
  class SaleEffectHold
    CODE = FinancialIntegrity::SALE_EFFECTS_HELD_CODE

    def self.owner?(payment)
      id = payment.respond_to?(:id) ? payment.id : payment
      # A legacy refund or dispute with no payment keeps today's behaviour.
      return true if id.nil?

      ActiveRecord::Base.connection.select_value(
        ActiveRecord::Base.sanitize_sql_array(["SELECT hafapass_sale_owner_payment(?)", id])
      ) == true
    end

    # Caller holds organization -> event -> order. Idempotent per movement.
    def self.hold!(source, reason:)
      existing = open_holds(source.order_id).find { |issue| issue.details.to_h.values_at("source_type", "source_id") == [source.class.name, source.id] }
      return existing if existing

      order = source.order
      issue = ReconciliationException.create!(order: order, payment: source.payment, code: CODE,
        actual_amount_cents: source.amount_cents, actual_currency: source.currency,
        details: { source_type: source.class.name, source_id: source.id, payment_id: source.payment_id,
          fulfilled_by_payment_id: order.fulfilled_by_payment_id, reason: reason })
      AuditLogger.record!(action: "never_fulfilled_capture.sale_effects_held", auditable: issue,
        organization: order.event.organization, event: order.event, source: "provider", outcome: "succeeded",
        deduplication_key: "sale_effects_held:#{source.class.name}:#{source.id}",
        metadata: { order_id: order.id, payment_id: source.payment_id, source_type: source.class.name,
          source_id: source.id, amount_cents: source.amount_cents, reason: reason })
      issue
    end

    def self.open_holds(order_id)
      ReconciliationException.open.where(order_id: order_id, code: CODE).order(:id).to_a
    end

    # Enqueued after commit wherever ownership or classification can change.
    def self.release_later!(order)
      SaleEffectHoldJob.perform_later(order.id) if ReconciliationException.open.where(order_id: order.id, code: CODE).exists?
    end

    # Takes organization -> event -> order, then replays or closes each hold
    # whose ownership is now decided. Returns the outcomes by exception ID.
    def self.release!(order)
      waitlist = false
      outcomes = Order.transaction do
        order.event.organization.lock!("FOR NO KEY UPDATE")
        order.event.lock!
        order.lock!
        open_holds(order.id).to_h do |issue|
          outcome = release_one!(issue)
          waitlist ||= outcome == "applied"
          [issue.id, outcome]
        end
      end
      order.event.notify_waitlist_if_available if waitlist
      outcomes
    end

    def self.release_one!(issue)
      details = issue.details.to_h
      source = details["source_type"].to_s.safe_constantize&.find_by(id: details["source_id"])
      return "missing" unless source.is_a?(Refund) || source.is_a?(Dispute)

      outcome = if UnfulfilledCapture.isolated_payment?(source.payment_id)
        # Classification posted the movement; the sale is never touched.
        "isolated"
      elsif !owner?(source.payment_id)
        return "held"
      elsif source.is_a?(Refund)
        source.succeeded? ? apply_refund!(source) : "not_succeeded"
      elsif source.lost? && source.loss_reversed_at.nil?
        cancel_disputed_tickets!(source.order, source, notify: false)
        "applied"
      else
        "loss_reversed"
      end
      issue.resolve_with_evidence!
      AuditLogger.record!(action: "never_fulfilled_capture.sale_effects_released", auditable: issue,
        organization: issue.order.event.organization, event: issue.order.event, outcome: "succeeded",
        deduplication_key: "sale_effects_released:#{issue.id}",
        after_data: { status: "resolved" },
        metadata: { code: CODE, order_id: issue.order_id, payment_id: source.payment_id,
          source_type: source.class.name, source_id: source.id, outcome: outcome,
          fulfilled_by_payment_id: issue.order.reload.fulfilled_by_payment_id })
      outcome
    end

    def self.apply_refund!(refund)
      RefundCreator.apply_held_sale_effects!(refund)
      "applied"
    end

    # The sale side of a lost dispute: the order's tickets are cancelled (or
    # retained when already admitted). Caller holds the dispute prefix.
    def self.cancel_disputed_tickets!(order, dispute, notify: true)
      seen_pass_parent_ids = Set.new
      order.tickets.includes(:ticket_type, :pricing_tier, :inventory_retention).order(:id).lock.each do |ticket|
        next if ticket.cancelled?

        pass_parent_id = FinancialReversalInventory.pass_group_parent_id(ticket)
        next if pass_parent_id && !seen_pass_parent_ids.add?(pass_parent_id)

        FinancialReversalInventory.call(ticket: ticket, dispute: dispute, reason: "payment_dispute_lost")
      end
      order.event.notify_waitlist_if_available if notify
      dispute
    end

    private_class_method :release_one!, :apply_refund!
  end
end
