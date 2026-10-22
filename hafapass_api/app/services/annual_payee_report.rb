# frozen_string_literal: true

require "openssl"

# Cash-basis preparation aid. A payee is the name/TIN identity frozen into a
# paid payout, not merely the organization's current W-9.
class AnnualPayeeReport
  attr_reader :organization, :year, :payee_key

  def self.payee_key_for(payout)
    snapshot = payout.tax_information_snapshot.to_h
    name = snapshot["legal_name"].presence || payout.payee_snapshot.to_h["payee_name"].to_s
    identity_key(name, payout.tax_information_tin)
  end

  # Single source for the payee identity key so reports and withholding
  # carry-forward always group the same payee together.
  def self.identity_key(legal_name, tin)
    OpenSSL::HMAC.hexdigest("SHA256", Rails.application.secret_key_base, "#{legal_name}\0#{tin}")
  end

  def self.for_organization(organization:, year:)
    all = new(organization: organization, year: year)
    keys = all.paid_payouts.map { |payout| payee_key_for(payout) }
    keys.concat(all.send(:refund_attributions).map { |entry| payee_key_for(entry[:payout]) })
    keys.uniq.sort.map do |key|
      new(organization: organization, year: year, payee_key: key)
    end
  end

  def self.unattributed_for_organization(organization:, year:)
    new(organization: organization, year: year).unattributed_refund_adjustment_cents
  end

  def initialize(organization:, year:, payee_key: nil)
    @organization = organization
    @year = Integer(year.to_s, 10)
    raise ArgumentError, "Choose a year from 2000 to 2100" unless (2000..2100).cover?(@year)

    @payee_key = payee_key
  end

  def paid_payouts
    @paid_payouts ||= begin
      payouts = organization.payouts.status_paid.where(paid_at: period).order(:id).to_a
      payee_key ? payouts.select { |payout| self.class.payee_key_for(payout) == payee_key } : payouts
    end
  end

  def unattributed_refund_adjustment_cents
    refund_adjustments.sum { |entry| entry[:payout] ? 0 : entry[:amount_cents] }
  end

  def row
    setting = AnnualTaxReportSetting.find_by(organization: organization, year: year, payee_key: payee_key || "all")
    form = setting&.form_type || "review_required"
    threshold_setting = AnnualTaxThreshold.for(year: year, form_type: form)
    threshold = threshold_setting&.amount_cents
    gross = paid_payouts.sum(&:amount_cents)
    withheld = paid_payouts.sum { |payout| payout.withheld_cents + payout.carried_withholding_cents }
    check_adjustments = paid_payouts.sum { |payout| payout.payout_check_adjustments.sum(:amount_cents) }
    first_payout = paid_payouts.first || refund_attributions.find { |entry| self.class.payee_key_for(entry[:payout]) == payee_key }&.dig(:payout)
    snapshot = first_payout&.tax_information_snapshot.to_h
    snapshot_name = snapshot["legal_name"].presence || first_payout&.payee_snapshot.to_h["payee_name"]
    payee_name = payee_key ? snapshot_name :
      (self.class.for_organization(organization: organization, year: year).length == 1 ? snapshot_name : "Multiple payees")
    { organization_id: organization.id, organization_name: organization.name, payee_key: payee_key,
      year: year, legal_name: payee_name, masked_tin: payee_key ? snapshot&.dig("masked_tin") : nil,
      form_type: form, jurisdiction: setting&.jurisdiction || "irs",
      threshold_cents: threshold, threshold_transaction_count: threshold_setting&.transaction_count,
      threshold_met: form == "1099-k" ? nil : (threshold && gross >= threshold),
      gross_paid_cents: gross, withheld_cents: withheld, net_disbursed_cents: gross - withheld + check_adjustments,
      check_amount_adjustment_cents: check_adjustments,
      refund_clawbacks_cents: refund_clawbacks_cents,
      reporting_status: withheld.positive? || check_adjustments.nonzero? || refund_clawbacks_cents.positive? || %w[review_required 1099-k].include?(form) ? "cpa_review" :
        form == "none" ? "not_reportable" : (gross >= threshold ? "prepare" : "below_threshold") }
  end

  def payee_tin
    return unless payee_key

    (paid_payouts.first || refund_attributions.find { |entry| self.class.payee_key_for(entry[:payout]) == payee_key }&.dig(:payout))&.tax_information_tin
  end

  def statement_pdf
    reports = self.class.for_organization(organization: organization, year: year)
    Prawn::Document.new(page_size: "LETTER", margin: 48) do |pdf|
      pdf.text "HåfaPass annual payee statement", size: 18, style: :bold
      pdf.move_down 8
      pdf.text "Calendar year #{year} - USD - Guam calendar dates"
      pdf.text "Organization: #{organization.name}"
      pdf.move_down 20
      if reports.empty?
        pdf.text "No paid payouts for this year."
      else
        reports.each do |report|
          data = report.row
          pdf.text "Payee: #{data[:legal_name] || 'W-9 not on file'}"
          pdf.text "TIN: #{data[:masked_tin] || 'Not on file'}"
          pdf.text "Gross payouts: #{money(data[:gross_paid_cents])}"
          pdf.text "Backup withholding: #{money(data[:withheld_cents])}"
          pdf.text "Checks/transfers to payee: #{money(data[:net_disbursed_cents])}"
          pdf.text "Post-payout refund adjustments: #{money(data[:refund_clawbacks_cents])}"
          pdf.text "Check amount adjustments: #{money(data[:check_amount_adjustment_cents])}" if data[:check_amount_adjustment_cents].nonzero?
          pdf.move_down 18
        end
      end
      excess = self.class.unattributed_for_organization(organization: organization, year: year)
      pdf.text "Unattributed refund adjustment for CPA review: #{money(excess)}" if excess.positive?
      pdf.text "This is an account statement, not a filed tax form. The payer and its CPA determine form, jurisdiction, " \
        "reportable amount, adjustments, and filing duties. Refund adjustments show refunded organizer proceeds " \
        "after a payout; they do not by themselves prove recovery."
    end.render
  end

  private

  def period
    zone = ActiveSupport::TimeZone["Pacific/Guam"]
    zone.local(year, 1, 1)...zone.local(year + 1, 1, 1)
  end

  def refund_attributions
    @refund_attributions ||= refund_adjustments.select { |entry| entry[:payout] }
  end

  def refund_adjustments
    @refund_adjustments ||= begin
      used = Hash.new(0)
      entries = []
      items = RefundItem.joins(refund: { order: :event })
        .where(events: { organization_id: organization.id }, refunds: { status: Refund.statuses[:succeeded] })
        .where("refunds.succeeded_at < ?", period.end)
        .includes(refund: :order).order("refunds.succeeded_at", "refund_items.id")
      items.each do |item|
        candidates = organization.payouts.status_paid.where(event_id: item.refund.order.event_id)
          .where("paid_at < ?", item.refund.succeeded_at).order(:paid_at, :id).to_a
        weights = candidates.filter_map do |payout|
          paid = PayoutLineAllocator.paid_for(payout, item.order_item_id)
          paid = payout.amount_cents if paid.zero? && candidates.one? && payout.settlement.settlement_items.empty?
          remaining = paid - used[[item.order_item_id, payout.id]]
          [payout, remaining] if remaining.positive?
        end
        total = weights.sum(&:last)
        attributed = [item.organizer_proceeds_cents, total].min
        shares = weights.map do |payout, available|
          numerator = attributed * available
          { payout: payout, available: available, cents: numerator / total, remainder: numerator % total }
        end
        remainder = attributed - shares.sum { |share| share[:cents] }
        shares.sort_by { |share| [-share[:remainder], share[:payout].id] }.each do |share|
          break if remainder.zero?
          next if share[:cents] >= share[:available]

          share[:cents] += 1
          remainder -= 1
        end
        next unless period.cover?(item.refund.succeeded_at) || shares.any?

        shares.each do |share|
          used[[item.order_item_id, share[:payout].id]] += share[:cents]
          entries << { item: item, payout: share[:payout], amount_cents: share[:cents] } if period.cover?(item.refund.succeeded_at) && share[:cents].positive?
        end
        excess = item.organizer_proceeds_cents - attributed
        entries << { item: item, payout: nil, amount_cents: excess } if excess.positive? && period.cover?(item.refund.succeeded_at)
      end
      entries
    end
  end

  def refund_clawbacks_cents
    refund_attributions.sum do |entry|
      payee_key.nil? || self.class.payee_key_for(entry[:payout]) == payee_key ? entry[:amount_cents] : 0
    end
  end

  def money(cents)
    format("$%.2f", cents.to_i / 100.0)
  end
end
