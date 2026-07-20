# frozen_string_literal: true

class PayoutGateway
  class PayoutError < StandardError; end

  Result = Data.define(:provider_payout_id, :status)

  def self.submit(payout)
    if Rails.env.test? || SiteSetting.instance.simulate_mode?
      return Result.new(provider_payout_id: "sim_po_#{SecureRandom.hex(12)}", status: :paid)
    end

    if %w[manual legacy_manual].include?(payout.provider)
      return Result.new(provider_payout_id: "manual_po_#{payout.id}", status: :processing)
    end

    raise PayoutError, "#{payout.provider.titleize} marketplace payouts require approved provider credentials"
  end
end
