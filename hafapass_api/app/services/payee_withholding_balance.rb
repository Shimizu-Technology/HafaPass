# frozen_string_literal: true

require "openssl"

# The organization lock serializes shortfall creation and collection. The key
# follows the frozen tax identity on each payout, including historical payees.
class PayeeWithholdingBalance
  def self.key_for(payout)
    AnnualPayeeReport.payee_key_for(payout)
  end

  def self.outstanding(organization:, key:, excluding: nil)
    payouts = organization.payouts.where(status: [:pending, :held, :processing, :paid]).to_a
    payouts.reject! { |payout| payout.id == excluding&.id }
    matching = payouts.select { |payout| key_for(payout) == key }
    shortfall = matching.select { |payout| payout.status_processing? || payout.status_paid? }
      .sum(&:under_withheld_cents)
    [shortfall - matching.sum(&:carried_withholding_cents), 0].max
  end

  def self.for_tax(tax)
    return 0 unless tax

    outstanding(organization: tax.organization, key: AnnualPayeeReport.identity_key(tax.legal_name, tax.tin))
  end

  def self.shortfall_for(payout)
    return 0 if payout.withholding_override_reason.present? &&
      AuditLog.where(auditable: payout, action: "payout.backup_withholding_overridden").exists?

    tax = payout.organization.organizer_tax_information&.reload
    needed = tax.nil? || tax.certified_at.nil? || tax.backup_withholding_required?
    return 0 unless needed

    required = (BigDecimal(payout.amount_cents.to_s) * SiteSetting.instance.backup_withholding_rate_bps / 10_000)
      .round(0, :half_up).to_i
    [required - payout.withheld_cents, 0].max
  end
end
