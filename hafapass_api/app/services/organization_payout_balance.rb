# frozen_string_literal: true

class OrganizationPayoutBalance
  def self.available_cents(organization)
    latest_settlements = organization.settlements.status_finalized
      .select("DISTINCT ON (event_id) settlements.*")
      .order(:event_id, version: :desc)
    entitlement_cents = Settlement.unscoped.from(latest_settlements, :latest_settlements).sum(
      Arel.sql(<<~SQL.squish)
        CASE
          WHEN latest_settlements.payable_cents > 0 THEN latest_settlements.payable_cents
          ELSE latest_settlements.paid_cents - latest_settlements.negative_balance_cents
        END
      SQL
    )
    committed_cents = organization.payouts.where(status: [:pending, :processing, :paid]).sum(:amount_cents)
    [entitlement_cents - committed_cents, 0].max
  end
end
