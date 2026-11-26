# frozen_string_literal: true

module Settlements
  class Finalizer
    class FinalizationError < StandardError; end

    def self.call(**)
      new(**).call
    end

    # Money that is still moving or unverified for the event, as an
    # instruction ("Resolve ...") the caller completes with its own action, or
    # nil. Shared with EventLifecycle#archive_blocker: an archived event
    # cannot be finalized again, so it must not be archived while any of
    # these is open.
    def self.open_money_blocker(event)
      return "Finish cancellation refunds" if EventCancellationRefunds.unresolved?(event)
      if event.orders.joins(:refunds).merge(Refund.pending).exists? || event.orders.joins(:disputes).merge(Dispute.open).exists?
        return "Resolve pending refunds and open disputes"
      end

      # The event-day closeout contract requires an empty reconciliation
      # queue, even when an item would not prevent a buyer refund attempt.
      # A proven platform-only over-return (P4) alerts finance without holding
      # the organizer, so it never blocks finalization; an unproven one does.
      open = Commerce::NeverFulfilledPayoutHold.holding_exceptions
      if event.orders.joins(:reconciliation_exceptions).merge(open).exists? ||
          open.joins(:payment).where(payments: { order_id: event.orders.select(:id) }).exists?
        return "Resolve open reconciliation exceptions"
      end
      return "Verify actual Stripe processing fees" if StripeProcessingFees.missing_count(event.orders.select(:id)).positive?

      nil
    end

    def initialize(event:, actor:, request: nil)
      @event = event
      @actor = actor
      @request = request
    end

    def call
      settlement = nil
      source_digest = nil
      Event.transaction do
        # FOR NO KEY UPDATE (docs/LOCKING.md): it still serializes with payout
        # creation, reserves, refunds, disputes and lifecycle changes, but lets
        # an order lifecycle that already holds the event insert its audit row
        # (organization FK KEY SHARE) instead of deadlocking with us.
        event.organization.lock!("FOR NO KEY UPDATE")
        event.lock!("FOR NO KEY UPDATE")
        unless event.completed? || event.cancelled?
          raise FinalizationError, "Only completed or cancelled events can be finalized"
        end
        if (blocker = self.class.open_money_blocker(event))
          raise FinalizationError, "#{blocker} before finalizing this event"
        end

        result = Calculator.call(event)
        source_digest = result.attributes[:source_digest]
        settlement = event.settlements.find_by(source_digest: result.attributes[:source_digest])
        next if settlement

        # This reader leaves never-fulfilled orders out; the database lets
        # only such a reader finalize an event that has one (finding 2).
        settlement = FinancialIntegrity.with_settlement_reader do
          event.settlements.create!(
            result.attributes.merge(
              version: event.settlements.maximum(:version).to_i + 1,
              status: :finalized,
              finalized_at: Time.current
            )
          )
        end
        result.items.each { |item| settlement.settlement_items.create!(item) }
        AuditLogger.record!(
          action: "settlement.finalized",
          auditable: settlement,
          actor: actor,
          organization: event.organization,
          after_data: settlement.attributes.slice(*Settlement::MONEY_COLUMNS.map(&:to_s), "version", "source_digest"),
          request: request
        )
      end
      settlement
    rescue ActiveRecord::RecordNotUnique
      event.settlements.find_by!(source_digest: source_digest)
    rescue ActiveRecord::RecordInvalid => e
      raise FinalizationError, e.record.errors.full_messages.to_sentence
    end

    private

    attr_reader :event, :actor, :request
  end
end
