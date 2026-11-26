# frozen_string_literal: true

# Validates 20261126180000's payouts_provider_accepted_basis_valid (added
# NOT VALID there, the repository's two-step form). Both columns are new and
# NULL on every existing row, so the scan finds nothing to reject.
#
# CodeRabbit 4707205533: explicit up and down. Rails records no inverse for
# validate_check_constraint (rolling back a `change` would validate again),
# so down restores 20261126180000's state exactly: the same constraint, NOT
# VALID. Rolling back 20261126180000 then removes it.
class ValidatePayoutAcceptedBasis < ActiveRecord::Migration[8.1]
  def up
    validate_check_constraint :payouts, name: "payouts_provider_accepted_basis_valid"
  end

  def down
    remove_check_constraint :payouts, name: "payouts_provider_accepted_basis_valid"
    add_check_constraint :payouts, FinancialIntegrity::PAYOUT_ACCEPTED_BASIS_CHECK,
      name: "payouts_provider_accepted_basis_valid", validate: false
  end
end
