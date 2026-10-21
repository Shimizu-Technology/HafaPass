# frozen_string_literal: true

class PayoutReconciler
  class ReconciliationError < StandardError
    attr_reader :conflict_audit_id

    def initialize(message, conflict_audit_id: nil)
      super(message)
      @conflict_audit_id = conflict_audit_id
    end
  end

  def self.call(payout:, actor:, status:, evidence:, provider_payout_id: nil, request: nil)
    raise ReconciliationError, "Administrator access is required" unless actor&.persisted? && actor.admin?
    raise ReconciliationError, "Status must be paid, failed, or reversed" unless %w[paid failed reversed].include?(status)

    normalized = normalize_evidence!(evidence)
    Payout.transaction do
      # Match payout reservation's organization-first locking, so releasing a
      # reservation and reserving a new payout cannot use competing snapshots.
      payout.organization.lock!
      payout.lock!
      if payout.failure_code == "provider_result_conflict"
        conflict = AuditLog.where(auditable: payout, action: "payout.provider_result_conflict").order(:id).last
        unless conflict && normalized["conflict_audit_id"] == conflict.id
          raise ReconciliationError.new("Review and acknowledge the latest provider conflict audit before recording an outcome",
            conflict_audit_id: conflict&.id)
        end
      end
      unless provider_payout_id.nil? || provider_payout_id.is_a?(String)
        raise ReconciliationError, "Transfer identifier must be text"
      end
      external_id = provider_payout_id.to_s.strip.presence || payout.provider_payout_id
      raise ReconciliationError, "Transfer identifier is too long" if external_id.to_s.length > 255
      if status == "paid" && (external_id.blank? || external_id.start_with?("sim_", "manual_po_"))
        raise ReconciliationError, "A real provider or bank transfer identifier is required to record payment"
      end
      if external_id.present? && external_id != payout.provider_payout_id &&
          Payout.where(provider: payout.provider, provider_payout_id: external_id).where.not(id: payout.id).exists?
        raise ReconciliationError, payout.provider == "check" ? "That check number is already recorded" :
          "That transfer identifier is already recorded"
      end
      confirmed_at = Time.iso8601(normalized.fetch("confirmed_at"))
      if confirmed_at < payout.created_at || confirmed_at > Time.current
        raise ReconciliationError, "Confirmation time must be after the payout request and not in the future"
      end

      if payout.status == status
        previous = AuditLog.where(auditable: payout, action: "payout.reconciled").order(:id).last
        same_evidence = previous&.metadata&.fetch("reconciliation", nil) == normalized
        return payout if same_evidence && payout.provider_payout_id == external_id

        raise ReconciliationError, "This payout outcome was already recorded with different evidence"
      end
      unless payout.may_reconcile_to?(status)
        raise ReconciliationError, "Payout cannot transition from #{payout.status} to #{status}"
      end
      if payout.status_paid? && external_id != payout.provider_payout_id
        raise ReconciliationError, "Keep the original transfer identifier when recording a reversal"
      end

      if status == "paid" && !payout.payee_matches_approval? && normalized["approved_payee_confirmed"] != true
        raise ReconciliationError, Payout::PAYEE_CHANGED_MESSAGE
      end

      before_data = payout.attributes.slice("status", "provider_payout_id", "paid_at")
      payout.update!(status: status, provider_payout_id: external_id,
        paid_at: status == "paid" ? confirmed_at : payout.paid_at,
        failure_code: status == "failed" ? "reconciled_failure" : nil,
        failure_message: status == "failed" ? normalized.fetch("reason") : nil)
      AuditLogger.record!(action: "payout.reconciled", auditable: payout, actor: actor,
        organization: payout.organization, before_data: before_data,
        after_data: payout.attributes.slice("status", "provider_payout_id", "paid_at"),
        metadata: { reconciliation: normalized }, request: request)
    end
    payout
  rescue ActiveRecord::RecordInvalid => e
    raise ReconciliationError, e.record.errors.full_messages.to_sentence
  end

  def self.normalize_evidence!(evidence)
    raise ReconciliationError, "Provider or bank confirmation evidence is required" unless evidence.is_a?(Hash)

    values = evidence.stringify_keys
    reference = values["reference"].to_s.strip
    reason = values["reason"].to_s.strip
    unless reference.present? && reference.length <= 500 && reason.present? && reason.length <= 1000
      raise ReconciliationError, "A confirmation reference and reconciliation reason are required"
    end
    timestamp = values["confirmed_at"].to_s
    raise ArgumentError unless timestamp.match?(/(?:Z|[+-]\d{2}:\d{2})\z/i)

    confirmed_at = Time.iso8601(timestamp)
    normalized = { "reference" => reference, "reason" => reason, "confirmed_at" => confirmed_at.utc.iso8601(6) }
    if values.key?("conflict_audit_id")
      conflict_id = values["conflict_audit_id"].to_s
      raise ReconciliationError, "Conflict audit identifier must be a positive integer" unless conflict_id.match?(/\A[1-9]\d*\z/)

      normalized["conflict_audit_id"] = conflict_id.to_i
    end
    # Recorded in the audit evidence when a check's details on file differ
    # from the approved payee the admin wrote the check to.
    if ActiveModel::Type::Boolean.new.cast(values["approved_payee_confirmed"])
      normalized["approved_payee_confirmed"] = true
    end
    normalized
  rescue ArgumentError
    raise ReconciliationError, "Confirmation time must be an ISO8601 timestamp with an offset"
  end
  private_class_method :normalize_evidence!
end
