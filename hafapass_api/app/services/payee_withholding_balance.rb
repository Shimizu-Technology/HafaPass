# frozen_string_literal: true

require "openssl"

# The organization lock serializes shortfall creation and collection. The key
# follows the frozen tax identity on each payout, including historical payees.
class PayeeWithholdingBalance
  def self.key_for(payout)
    AnnualPayeeReport.payee_key_for(payout)
  end

  def self.outstanding(organization:, key:, excluding: nil)
    payouts = organization.payouts.where(status: [:processing, :paid]).to_a
    payouts.reject! { |payout| payout.id == excluding&.id }
    matching = payouts.select { |payout| key_for(payout) == key }
    [matching.sum(&:under_withheld_cents) - matching.sum(&:carried_withholding_cents), 0].max
  end

  def self.for_tax(tax)
    return 0 unless tax

    key = OpenSSL::HMAC.hexdigest("SHA256", Rails.application.secret_key_base,
      "#{tax.legal_name}\0#{tax.tin}")
    outstanding(organization: tax.organization, key: key)
  end

  def self.shortfall_for(payout)
    tax = payout.organization.organizer_tax_information&.reload
    needed = tax.nil? || tax.certified_at.nil? || tax.backup_withholding_required?
    return 0 unless needed

    required = (BigDecimal(payout.amount_cents.to_s) * SiteSetting.instance.backup_withholding_rate_bps / 10_000)
      .round(0, :half_up).to_i
    [required - payout.withheld_cents, 0].max
  end
end
