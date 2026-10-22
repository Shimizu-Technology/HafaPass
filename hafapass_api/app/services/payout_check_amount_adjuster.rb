# frozen_string_literal: true

class PayoutCheckAmountAdjuster
  class AdjustmentError < StandardError; end

  def self.call(payout:, actor:, actual_check_amount_cents:, reason:, request: nil)
    raise AdjustmentError, "Administrator access is required" unless actor&.persisted? && actor.admin?
    amount = actual_check_amount_cents.to_s
    unless amount.match?(/\A[1-9]\d*\z/) && amount.to_i <= 2_147_483_647
      raise AdjustmentError, "Enter a positive actual check amount in cents"
    end
    reason = reason.to_s.strip
    unless BackupWithholding.safe_reason?(reason)
      raise AdjustmentError, BackupWithholding.safe_text?(reason) ?
        "Give a 10-1000 character adjustment reason" : BackupWithholding::TIN_WARNING
    end

    payout.organization.with_lock do
      payout.lock!
      unless payout.provider == "check" && (payout.status_processing? ||
          payout.status_held? && payout.held_from_status == "processing")
        raise AdjustmentError, "Only an issued check awaiting reconciliation can be adjusted"
      end
      before_amount = payout.confirmed_check_amount_cents
      delta = amount.to_i - before_amount
      raise AdjustmentError, "Actual check amount already matches the recorded amount" if delta.zero?

      adjustment = payout.payout_check_adjustments.create!(amount_cents: delta, reason: reason,
        created_by_user: actor)
      AuditLogger.record!(action: "payout.check_amount_adjusted", auditable: payout, actor: actor,
        organization: payout.organization, before_data: { check_amount_cents: before_amount },
        after_data: { check_amount_cents: amount.to_i },
        metadata: { adjustment_id: adjustment.id, delta_cents: delta, reason: reason }, request: request)
      adjustment
    end
  end
end
