# frozen_string_literal: true

# Call only while the organization and payout are locked. The organization lock
# serializes this decision with tax-information and withholding-flag changes.
class PayoutWithholdingGuard
  class WithholdingError < StandardError; end

  def self.call(payout:, actor:, override_reason: nil, request: nil, allow_recalculation: true)
    raise WithholdingError, BackupWithholding::TIN_WARNING unless BackupWithholding.safe_text?(override_reason)
    # A check or transfer may already be in the payee's hands. Reconciliation
    # records a shortfall separately; it never rewrites the submitted amount.
    if payout.status_processing? || payout.status_paid? || payout.held_from_status == "processing"
      raise WithholdingError, "A submitted payout cannot receive a withholding override" if override_reason.present?

      return payout
    end

    tax = payout.organization.organizer_tax_information&.reload
    needed = tax.nil? || tax.certified_at.nil? || tax.backup_withholding_required?
    reason = override_reason.to_s.strip
    carry = PayeeWithholdingBalance.outstanding(organization: payout.organization,
      key: PayeeWithholdingBalance.key_for(payout), excluding: payout)
    previously_overridden = payout.withholding_override_reason.present? &&
      AuditLog.where(auditable: payout, action: "payout.backup_withholding_overridden").exists?
    if previously_overridden
      raise WithholdingError, "This payout already has an audited withholding override" if reason.present?
    end
    raise WithholdingError, "No withholding override is needed" if !needed && reason.present?
    if needed && reason.present?
      unless actor&.admin? && BackupWithholding.safe_reason?(reason)
        raise WithholdingError, BackupWithholding.safe_text?(reason) ?
          "An admin withholding override needs a 10-1000 character reason" : BackupWithholding::TIN_WARNING
      end
      raise WithholdingError, "A submitted payout needs withholding review before its provider result can be recorded" unless allow_recalculation
      payout.update!(withholding_override_reason: reason)
      AuditLogger.record!(action: "payout.backup_withholding_overridden", auditable: payout,
        actor: actor, organization: payout.organization, metadata: { reason: reason, stage: "transition" }, request: request)
    end

    if needed && !previously_overridden && reason.blank? && SiteSetting.instance.backup_withholding_mode == "block"
      raise WithholdingError, "Backup withholding review blocks this payout. An admin may override with a reason."
    end
    rate = SiteSetting.instance.backup_withholding_rate_bps
    own = needed && !previously_overridden && reason.blank? ?
      (BigDecimal(payout.amount_cents.to_s) * rate / 10_000).round(0, :half_up).to_i : 0
    raise WithholdingError, "Withholding leaves no amount to disburse" if own >= payout.amount_cents

    collected = [carry, payout.amount_cents - own].min
    expected = own
    expected_rate = own.positive? ? rate : 0
    expected_reason = if own.positive?
      tax.nil? || tax.certified_at.nil? ? "missing_w9" : "tin_or_admin_flag"
    elsif reason.present? || previously_overridden && needed
      "admin_override"
    elsif collected.positive?
      "carried_shortfall"
    end
    return payout if payout.withheld_cents == expected && payout.withholding_rate_bps == expected_rate &&
      payout.withholding_reason == expected_reason && payout.carried_withholding_cents == collected

    raise WithholdingError, "A submitted payout needs withholding review before its provider result can be recorded" unless allow_recalculation

    adjust!(payout: payout, actor: actor, request: request, withheld_cents: expected,
      withholding_rate_bps: expected_rate, withholding_reason: expected_reason,
      carried_withholding_cents: collected, keep_override: previously_overridden || reason.present?)
    payout
  end

  def self.adjust!(payout:, actor:, request:, withheld_cents:, withholding_rate_bps:, withholding_reason:,
    carried_withholding_cents:, keep_override:)
    before_data = payout.attributes.slice("withheld_cents", "withholding_rate_bps", "withholding_reason",
      "carried_withholding_cents")
    payout.update!(withheld_cents: withheld_cents, withholding_rate_bps: withholding_rate_bps,
      withholding_reason: withholding_reason,
      carried_withholding_cents: carried_withholding_cents,
      withholding_override_reason: keep_override ? payout.withholding_override_reason : nil)
    AuditLogger.record!(action: "payout.backup_withholding_recalculated", auditable: payout,
      actor: actor, organization: payout.organization, before_data: before_data,
      after_data: payout.attributes.slice("withheld_cents", "withholding_rate_bps", "withholding_reason",
        "carried_withholding_cents"),
      request: request)
  end
end
