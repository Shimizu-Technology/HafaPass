# frozen_string_literal: true

require_relative "../../lib/financial_integrity"

# A1-R1 review fixes (docs/design/never-fulfilled-captures.md §6.7). Adds
# database guards on the writes that cause sale, payout and refund-identity
# effects, and closes evidence holds only through evidence paths. Additive:
# functions and triggers only, no table or column. The running release
# (7bcd97c2) is refused only where it would change a sale from a payment
# that does not own it, authorize, record as paid or finalize on an event
# with an open blocking never-fulfilled item, close an evidence hold by note,
# or bind a provider refund to a fenced payment's outbound row. Each refusal
# rolls back its whole transaction, so the provider fact stays in its signed
# receipt and is applied later by this release. It runs as a pre-deploy
# migration, so the guards exist before any R1 process starts.
class AddSaleOwnershipAndPayoutEvidenceGuards < ActiveRecord::Migration[8.1]
  def up
    safety_assured do
      execute FinancialIntegrity::EVIDENCE_SQL
      execute "INSERT INTO financial_cutovers (key) VALUES ('a1_evidence_guards') ON CONFLICT (key) DO NOTHING"
    end
  end

  def down
    safety_assured do
      execute <<~SQL
        DROP TRIGGER IF EXISTS refund_items_sale_ownership ON refund_items;
        DROP TRIGGER IF EXISTS promoter_commission_entries_sale_ownership ON promoter_commission_entries;
        DROP TRIGGER IF EXISTS ticket_inventory_retentions_sale_ownership ON ticket_inventory_retentions;
        DROP TRIGGER IF EXISTS tickets_dispute_sale_ownership ON tickets;
        DROP TRIGGER IF EXISTS audit_logs_payout_submission_fence ON audit_logs;
        DROP TRIGGER IF EXISTS settlements_finalization_fence ON settlements;
        DROP TRIGGER IF EXISTS reconciliation_exceptions_evidence_hold ON reconciliation_exceptions;
        DROP TRIGGER IF EXISTS refunds_identity_fence ON refunds;
        DROP FUNCTION IF EXISTS hafapass_sale_effect_guard();
        DROP FUNCTION IF EXISTS hafapass_payout_submission_fence();
        DROP FUNCTION IF EXISTS hafapass_settlement_finalization_fence();
        DROP FUNCTION IF EXISTS hafapass_evidence_hold_guard();
        DROP FUNCTION IF EXISTS hafapass_refund_identity_fence();
        DROP FUNCTION IF EXISTS hafapass_sale_owner_payment(bigint);
        DROP FUNCTION IF EXISTS hafapass_live_or_legacy(text, jsonb);
      SQL
      # The payout fence keeps working; restore the tranche 4 definition.
      execute FinancialIntegrity::REPAYMENT_SQL.split("CREATE OR REPLACE FUNCTION hafapass_payout_repayment_fence()").then { |parts|
        "CREATE OR REPLACE FUNCTION hafapass_payout_repayment_fence()#{parts.last}"
      }
      execute "DROP FUNCTION IF EXISTS hafapass_payout_block_start(bigint)"
    end
  end
end
