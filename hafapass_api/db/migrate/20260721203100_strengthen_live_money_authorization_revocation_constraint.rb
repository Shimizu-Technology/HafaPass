# frozen_string_literal: true

class StrengthenLiveMoneyAuthorizationRevocationConstraint < ActiveRecord::Migration[8.1]
  def up
    remove_check_constraint :live_money_proof_authorizations,
      name: "live_money_authorizations_revocation_valid"
    add_check_constraint :live_money_proof_authorizations,
      "(revoked_at IS NULL AND revocation_reason IS NULL) OR " \
      "(revoked_at IS NOT NULL AND revocation_reason IS NOT NULL AND length(btrim(revocation_reason)) > 0)",
      name: "live_money_authorizations_revocation_valid"
  end

  def down
    remove_check_constraint :live_money_proof_authorizations,
      name: "live_money_authorizations_revocation_valid"
    add_check_constraint :live_money_proof_authorizations,
      "(revoked_at IS NULL AND revocation_reason IS NULL) OR " \
      "(revoked_at IS NOT NULL AND length(btrim(revocation_reason)) > 0)",
      name: "live_money_authorizations_revocation_valid"
  end
end
