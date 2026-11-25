# frozen_string_literal: true

require_relative "../../lib/financial_integrity"

# A1-R1 recheck fixes (docs/design/never-fulfilled-captures.md §6.8).
# Additive: functions and triggers only, no table or column. Runs as a
# pre-deploy migration, so the guards exist before any R1 process starts and
# stay through a rollback to 7bcd97c2. They refuse, for every writer:
#
#   - an order refund total or refunded status that counts a refund on a
#     payment that does not own the sale (an older release's order-wide sum);
#   - recording a payout as paid on a held event without its pre-hold
#     submission, a transfer time before the hold and this release's
#     verified confirmation (a submission is not a transfer);
#   - payouts and statements on an event with a capture no release has
#     classified (an older release acknowledges a second capture silently).
#
# Clearing a signed receipt's payload (retention or a privacy request, from
# either release) keeps its provider identity in the non-personal columns.
# Each refusal rolls back its whole transaction; a refused webhook stays
# failed with its signed receipt, and this release applies the redelivery.
class AddOverlapAggregateAndTransferEvidenceGuards < ActiveRecord::Migration[8.1]
  def up
    safety_assured do
      execute FinancialIntegrity::OVERLAP_SQL
      execute "INSERT INTO financial_cutovers (key) VALUES ('a1_overlap_guards') ON CONFLICT (key) DO NOTHING"
    end
  end

  def down
    safety_assured do
      execute <<~SQL
        DROP TRIGGER IF EXISTS orders_sale_refund_aggregate ON orders;
        DROP TRIGGER IF EXISTS webhook_events_keep_identity ON webhook_events;
        DROP FUNCTION IF EXISTS hafapass_guard_order_refund_aggregate();
        DROP FUNCTION IF EXISTS hafapass_sale_refund_total(bigint);
        DROP FUNCTION IF EXISTS hafapass_keep_receipt_identity();
      SQL
      # The payout fence and block start keep working with their 20261126130000 definitions.
      evidence = FinancialIntegrity::EVIDENCE_SQL
      [["CREATE OR REPLACE FUNCTION hafapass_payout_block_start", "-- An event whose never-fulfilled order"],
        ["CREATE OR REPLACE FUNCTION hafapass_payout_repayment_fence()", "-- The actual submission authorization"]].each do |start, stop|
        execute evidence[evidence.index(start)...evidence.index(stop)]
      end
      execute "DROP FUNCTION IF EXISTS hafapass_unclassified_capture(bigint)"
    end
  end
end
