# frozen_string_literal: true

module Commerce
  class FinancialReversalInventory
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
  end
end
