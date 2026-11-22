# frozen_string_literal: true

module Commerce
  class FinancialReversalInventory
    def self.pass_group_parent_id(ticket)
      return ticket.parent_ticket_id if ticket.pass_child?
      return ticket.id if ticket.pass_parent?

      nil
    end

    # Financial reversal is not evidence that an admitted guest has exited.
    # Keep both sold counters and active seat uniqueness until a separately
    # reviewed physical reconciliation; Undo and exception resolution cannot release them.
    def self.call(ticket:, refund: nil, dispute: nil, reason: nil)
      origin = refund || dispute
      unless refund.present? != dispute.present? && origin.persisted? && ticket.persisted? && origin.order_id == ticket.order_id &&
          (refund ? refund.succeeded? : dispute.lost?)
        raise ArgumentError, "Inventory reversal requires the ticket's succeeded refund or lost dispute"
      end
      ticket.order.with_lock do
        parent = ticket.pass_child? ? ticket.parent_ticket : ticket
        if parent&.pass_parent?
          return reverse_pass_parent!(parent, origin: origin, refund: refund, dispute: dispute, reason: reason)
        end

        ticket.with_lock do
          return if ticket.cancelled?
          existing = ticket.inventory_retention
          return existing if existing

          if ticket.previously_admitted?
            exception = ReconciliationException.create!(order: ticket.order, payment: origin.payment,
              code: "admitted_inventory_retained", details: { ticket_id: ticket.id,
                refund_id: refund&.id, dispute_id: dispute&.id }.compact)
            ticket.create_inventory_retention!(refund: refund, dispute: dispute,
              reconciliation_exception: exception, retained_at: Time.current)
          else
            ticket.release_inventory!
            ticket.update!(status: :cancelled, cancelled_at: Time.current,
              cancellation_reason: reason, scan_credential_version: ticket.scan_credential_version + 1)
          end
        end
      end
    end

    # Multi-night pass reversal: locks parent + all children in ascending ticket.id
    # order under the already-held pass order lock (never locking night events).
    # Unused passes cancel parent + all children and release 1 pass unit on parent.
    # Partially used passes cancel all unadmitted children, retain admitted children
    # and the parent's sold unit, and record ONE grouped ReconciliationException.
    def self.reverse_pass_parent!(parent, origin:, refund:, dispute:, reason:)
      group = parent.order.tickets
        .where(id: parent.id)
        .or(parent.order.tickets.where(parent_ticket_id: parent.id))
        .includes(:ticket_type, :pricing_tier, :inventory_retention)
        .order(:id)
        .lock
        .to_a
      locked_parent = group.find { |item| item.id == parent.id }
      return unless locked_parent

      children = group.reject { |item| item.id == locked_parent.id }
      admitted_children = children.select(&:previously_admitted?)
      now = Time.current

      if locked_parent.previously_admitted? || admitted_children.any?
        children.each do |child|
          next if child.cancelled? || child.previously_admitted?

          child.update!(
            status: :cancelled,
            cancelled_at: now,
            cancellation_reason: reason,
            scan_credential_version: child.scan_credential_version + 1
          )
        end

        existing = locked_parent.inventory_retention
        return existing if existing
        return if locked_parent.cancelled?

        exception = ReconciliationException.create!(
          order: locked_parent.order,
          payment: origin.payment,
          code: "admitted_inventory_retained",
          details: {
            ticket_id: locked_parent.id,
            parent_ticket_id: locked_parent.id,
            admitted_child_ticket_ids: admitted_children.map(&:id),
            refund_id: refund&.id,
            dispute_id: dispute&.id
          }.compact
        )
        locked_parent.create_inventory_retention!(
          refund: refund,
          dispute: dispute,
          reconciliation_exception: exception,
          retained_at: now
        )
      else
        unless locked_parent.cancelled?
          locked_parent.release_inventory!
          locked_parent.update!(
            status: :cancelled,
            cancelled_at: now,
            cancellation_reason: reason,
            scan_credential_version: locked_parent.scan_credential_version + 1
          )
        end
        children.each do |child|
          next if child.cancelled?

          child.update!(
            status: :cancelled,
            cancelled_at: now,
            cancellation_reason: reason,
            scan_credential_version: child.scan_credential_version + 1
          )
        end
        nil
      end
    end
    private_class_method :reverse_pass_parent!
  end
end
