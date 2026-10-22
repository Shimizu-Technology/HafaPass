# frozen_string_literal: true

class PayoutHoldRelease
  class ReleaseError < StandardError; end

  def self.call(payout:, actor:, automatic: false, withholding_override_reason: nil, request: nil)
    raise ReleaseError, "Administrator access is required" unless automatic || actor&.persisted? && actor.admin?

    released = false
    payout.organization.with_lock do
      payout.event.with_lock do
        payout.with_lock do
          raise ReleaseError, "Payout is not on hold" unless payout.status_held?
          unless %w[pending processing].include?(payout.held_from_status)
            raise ReleaseError, "Original payout status is unknown; cancel and reissue this payout"
          end
          if %w[provider_result_conflict provider_result_unknown].include?(payout.failure_code)
            raise ReleaseError, "Resolve the provider result conflict before releasing this payout"
          end

          PayoutWithholdingGuard.call(payout: payout, actor: actor,
            override_reason: withholding_override_reason, request: request)

          liability = payout.event.cancelled? ? EventCancellationRefunds.liability_snapshot(payout.event) :
            { outstanding_cents: 0, unresolved: false }
          queue_outstanding = RefundReconciliationQueue.outstanding_for_event?(payout.event)
          if liability[:unresolved] || queue_outstanding
            raise ReleaseError, "Resolve outstanding buyer refund liabilities before releasing this payout"
          end

          payable = Settlements::Calculator.call(payout.event).attributes.fetch(:payable_cents)
          other_reserved = payout.event.payouts.where(status: [:pending, :processing, :held, :paid])
            .where.not(id: payout.id).sum(:amount_cents)
          available = [payable - other_reserved, 0].max
          if payout.amount_cents > available
            raise ReleaseError, "Held payout exceeds the event's current net payable; cancel and reissue it for the correct amount"
          end

          before_data = payout.attributes.slice("status", "held_from_status", "failure_code", "failure_message")
          payout.update!(status: payout.held_from_status, held_from_status: nil,
            failure_code: nil, failure_message: nil)
          AuditLogger.record!(action: "payout.released_from_cancellation_hold", auditable: payout,
            actor: actor, organization: payout.organization, before_data: before_data,
            after_data: payout.attributes.slice("status", "held_from_status", "failure_code", "failure_message"),
            metadata: { event_id: payout.event_id, current_payable_cents: payable,
              other_reserved_cents: other_reserved, outstanding_buyer_balance_cents: liability[:outstanding_cents],
              automatic: automatic }, request: request)
          released = true
        end
      end
    end
    released
  rescue PayoutWithholdingGuard::WithholdingError => e
    raise ReleaseError, e.message unless automatic

    false
  rescue ReleaseError
    raise unless automatic

    false
  end
end
