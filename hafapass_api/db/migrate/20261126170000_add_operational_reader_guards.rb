# frozen_string_literal: true

require_relative "../../lib/financial_integrity"

# A2 operational readers (docs/design/never-fulfilled-captures.md §8.7,
# §8.10.9). Additive:
#   - hafapass_overpaid_platform_only(payment), the P4 proof, and
#     hafapass_payout_block_start redefined so an open
#     never_fulfilled_buyer_overpaid holds the event's payouts and
#     finalization unless its capture is proven platform-only. The payout,
#     submission and finalization fences already call that function, so the
#     database and the application readers agree;
#   - stripe_fee_evidences.facts_recorded_at, a database-stamped, set-once
#     recording time for verified processing facts, so payment-scope
#     processing with no fee component can be booked in a period.
# No existing row changes. Rows that already hold facts keep NULL until
# `bin/rails stripe_fee_evidence:stamp_facts` stamps them when it runs.
class AddOperationalReaderGuards < ActiveRecord::Migration[8.1]
  def up
    add_column :stripe_fee_evidences, :facts_recorded_at, :datetime
    safety_assured { execute FinancialIntegrity::OPERATIONAL_SQL }
  end

  def down
    safety_assured do
      execute "DROP TRIGGER IF EXISTS stripe_fee_evidences_facts_recorded_at ON stripe_fee_evidences"
      execute "DROP FUNCTION IF EXISTS hafapass_stamp_fee_facts_recorded_at()"
      # Restores the previous hold (A1-R1 boundary fix) before dropping the
      # proof it no longer calls.
      execute FinancialIntegrity::BOUNDARY_SQL
      execute "DROP FUNCTION IF EXISTS hafapass_overpaid_platform_only(bigint)"
    end
    remove_column :stripe_fee_evidences, :facts_recorded_at
  end
end
