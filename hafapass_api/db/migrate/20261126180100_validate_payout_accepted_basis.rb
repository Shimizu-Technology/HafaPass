# frozen_string_literal: true

# Validates 20261126180000's payouts_provider_accepted_basis_valid (added
# NOT VALID there, the repository's two-step form). Both columns are new and
# NULL on every existing row, so the scan finds nothing to reject.
class ValidatePayoutAcceptedBasis < ActiveRecord::Migration[8.1]
  def change
    validate_check_constraint :payouts, name: "payouts_provider_accepted_basis_valid"
  end
end
