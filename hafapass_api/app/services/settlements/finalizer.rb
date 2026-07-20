# frozen_string_literal: true

module Settlements
  class Finalizer
    class FinalizationError < StandardError; end

    def self.call(**)
      new(**).call
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
        event.lock!
        unless event.completed? || event.cancelled?
          raise FinalizationError, "Only completed or cancelled events can be finalized"
        end
        if event.orders.joins(:refunds).merge(Refund.pending).exists? || event.orders.joins(:disputes).merge(Dispute.open).exists?
          raise FinalizationError, "Resolve pending refunds and open disputes before finalizing"
        end

        result = Calculator.call(event)
        source_digest = result.attributes[:source_digest]
        settlement = event.settlements.find_by(source_digest: result.attributes[:source_digest])
        next if settlement

        settlement = event.settlements.create!(
          result.attributes.merge(
            version: event.settlements.maximum(:version).to_i + 1,
            status: :finalized,
            finalized_at: Time.current
          )
        )
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
