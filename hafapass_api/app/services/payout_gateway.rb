# frozen_string_literal: true

class PayoutGateway
  class PayoutError < StandardError; end

  Result = Data.define(:provider_payout_id, :status)

  def self.submit(payout)
    raise PayoutError, "Payout submission is disabled in staging" if Rails.env.staging?

    # A mutable checkout setting cannot turn historical liabilities into a
    # simulated transfer. Synthetic paid results are local rehearsal only.
    if Rails.env.production? && SiteSetting.instance.simulate_mode?
      raise PayoutError, "Simulated payouts are disabled in production; reconcile an actual transfer"
    end

    if Rails.env.test? || (Rails.env.development? && SiteSetting.instance.simulate_mode?)
      if Payment.where(order_id: payout.event.orders.select(:id), provider_environment: "live").exists?
        raise PayoutError, "Live payment proceeds cannot be paid through simulation"
      end
      return Result.new(provider_payout_id: "sim_po_#{SecureRandom.hex(12)}", status: :paid)
    end

    if %w[manual legacy_manual].include?(payout.provider)
      return Result.new(provider_payout_id: "manual_po_#{payout.id}", status: :processing)
    end

    raise PayoutError, "#{payout.provider.titleize} marketplace payouts require approved provider credentials"
  end
end
