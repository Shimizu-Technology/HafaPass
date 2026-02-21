class AddPricingTierToTickets < ActiveRecord::Migration[8.1]
  def change
    add_reference :tickets, :pricing_tier, null: true, foreign_key: true
  end
end
