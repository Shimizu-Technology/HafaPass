# frozen_string_literal: true

# Call only while the organization and payout are locked. The organization lock
# serializes this decision with tax-information and withholding-flag changes.
class PayoutWithholdingGuard
  class WithholdingError < StandardError; end

  def self.call(payout:, actor:, override_reason: nil, request: nil, allow_recalculation: true)
    tax = payout.organization.organizer_tax_information&.reload
    needed = tax.nil? || tax.certified_at.nil? || tax.backup_withholding_required?
    reason = override_reason.to_s.strip
    previously_overridden = payout.withholding_override_reason.present? &&
      AuditLog.where(auditable: payout, action: "payout.backup_withholding_overridden").exists?
    if previously_overridden
      raise WithholdingError, "This payout already has an audited withholding override" if reason.present?

      return payout if needed
    end

    unless needed
      raise WithholdingError, "No withholding override is needed" if reason.present?

      if payout.withheld_cents.positive? || payout.withholding_rate_bps.positive? || payout.withholding_reason.present? ||
          payout.withholding_override_reason.present?
        raise WithholdingError, "A submitted payout needs withholding review before its provider result can be recorded" unless allow_recalculation

        adjust!(payout: payout, actor: actor, request: request, withheld_cents: 0,
          withholding_rate_bps: 0, withholding_reason: nil)
      end
      return payout
    end

    if reason.present?
      unless actor&.admin? && BackupWithholding.safe_reason?(reason)
        raise WithholdingError, BackupWithholding.safe_text?(reason) ?
          "An admin withholding override needs a 10-1000 character reason" : BackupWithholding::TIN_WARNING
      end
      payout.update!(withheld_cents: 0, withholding_rate_bps: 0,
        withholding_override_reason: reason, withholding_reason: "admin_override")
      AuditLogger.record!(action: "payout.backup_withholding_overridden", auditable: payout,
        actor: actor, organization: payout.organization, metadata: { reason: reason, stage: "transition" }, request: request)
      return payout
    end

    if SiteSetting.instance.backup_withholding_mode == "block"
      raise WithholdingError, "Backup withholding review blocks this payout. An admin may override with a reason."
    end
    rate = SiteSetting.instance.backup_withholding_rate_bps
    expected = (BigDecimal(payout.amount_cents.to_s) * rate / 10_000).round(0, :half_up).to_i
    expected_reason = tax.nil? || tax.certified_at.nil? ? "missing_w9" : "tin_or_admin_flag"
    return payout if payout.withheld_cents == expected && payout.withholding_rate_bps == rate &&
      payout.withholding_reason == expected_reason && payout.withholding_override_reason.blank?

    raise WithholdingError, "A submitted payout needs withholding review before its provider result can be recorded" unless allow_recalculation
    raise WithholdingError, "Withholding leaves no amount to disburse" if expected >= payout.amount_cents

    adjust!(payout: payout, actor: actor, request: request, withheld_cents: expected,
      withholding_rate_bps: rate, withholding_reason: expected_reason)
    payout
  end

  def self.adjust!(payout:, actor:, request:, withheld_cents:, withholding_rate_bps:, withholding_reason:)
    before_data = payout.attributes.slice("withheld_cents", "withholding_rate_bps", "withholding_reason")
    payout.update!(withheld_cents: withheld_cents, withholding_rate_bps: withholding_rate_bps,
      withholding_reason: withholding_reason,
      withholding_override_reason: nil)
    AuditLogger.record!(action: "payout.backup_withholding_recalculated", auditable: payout,
      actor: actor, organization: payout.organization, before_data: before_data,
      after_data: payout.attributes.slice("withheld_cents", "withholding_rate_bps", "withholding_reason"),
      request: request)
  end
end
