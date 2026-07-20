# frozen_string_literal: true

class OrganizationPayoutBalance
  def self.available_cents(organization)
    eligible_events = organization.events.joins(:settlements).merge(Settlement.status_finalized).distinct
    entitlement_cents = eligible_events.sum do |event|
      attributes = Settlements::Calculator.call(event).attributes
      if attributes[:payable_cents].positive?
        attributes[:payable_cents]
      else
        attributes[:paid_cents] - attributes[:negative_balance_cents]
      end
    end
    committed_cents = organization.payouts.where(status: [:pending, :processing, :paid]).sum(:amount_cents)
    [entitlement_cents - committed_cents, 0].max
  end
end
