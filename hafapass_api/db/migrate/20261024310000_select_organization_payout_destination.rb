# frozen_string_literal: true

class SelectOrganizationPayoutDestination < ActiveRecord::Migration[8.0]
  def change
    add_reference :organizations, :payout_connected_account, foreign_key: { to_table: :connected_accounts }
    reversible do |direction|
      direction.up do
        # Preserve an unambiguous supported destination only. Multiple accounts
        # require an explicit choice; never infer a destination from row order.
        execute <<~SQL
          UPDATE organizations SET payout_connected_account_id = candidates.account_id
          FROM (
            SELECT organization_id, MIN(id) AS account_id FROM connected_accounts
            WHERE provider NOT IN ('manual', 'legacy_manual') AND status <> 5
            GROUP BY organization_id HAVING COUNT(*) = 1
          ) candidates WHERE organizations.id = candidates.organization_id
        SQL
      end
    end
  end
end
