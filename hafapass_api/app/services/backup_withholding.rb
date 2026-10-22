# frozen_string_literal: true

class BackupWithholding
  class WithholdingError < StandardError; end

  def self.safe_text?(value)
    !value.to_s.gsub(/\D/, "").match?(/\d{9}/)
  end

  def self.safe_reason?(value)
    value.to_s.match?(/\A.{10,1000}\z/m) && safe_text?(value)
  end

  def self.for_payout(organization:, amount_cents:, actor:, override_reason: nil)
    tax = organization.organizer_tax_information
    needed = tax.nil? || tax.certified_at.nil? || tax.backup_withholding_required?
    return { withheld_cents: 0, withholding_rate_bps: 0 } unless needed

    mode = SiteSetting.instance.backup_withholding_mode
    if mode == "block" && override_reason.blank?
      raise WithholdingError, "Backup withholding review blocks this payout. An admin may override with a reason."
    end
    if override_reason.present? && (!actor&.admin? || !safe_reason?(override_reason.to_s.strip))
      raise WithholdingError, "An admin override needs a 10-1000 character reason without a TIN"
    end
    if mode == "block" && override_reason.present?
      return { withheld_cents: 0, withholding_rate_bps: 0,
        withholding_override_reason: override_reason.to_s.strip, withholding_reason: "admin_override" }
    end

    rate = SiteSetting.instance.backup_withholding_rate_bps
    withheld = (BigDecimal(amount_cents.to_s) * rate / 10_000).round(0, :half_up).to_i
    raise WithholdingError, "Withholding leaves no amount to disburse" if withheld >= amount_cents

    { withheld_cents: withheld, withholding_rate_bps: rate,
      withholding_reason: tax.nil? || tax.certified_at.nil? ? "missing_w9" : "tin_or_admin_flag" }
  end
end
