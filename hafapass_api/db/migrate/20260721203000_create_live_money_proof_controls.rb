# frozen_string_literal: true

class CreateLiveMoneyProofControls < ActiveRecord::Migration[8.1]
  def change
    add_column :events, :live_money_proof_candidate, :boolean, null: false, default: false
    add_index :events, :live_money_proof_candidate

    create_table :live_money_proof_authorizations do |t|
      t.references :event, null: false, foreign_key: { on_delete: :restrict }
      t.references :connected_account, null: false, foreign_key: { on_delete: :restrict }
      t.references :event_day_rehearsal_review, null: false, foreign_key: { on_delete: :restrict }
      t.references :requested_by_user, null: false, foreign_key: { to_table: :users, on_delete: :restrict }
      t.references :approved_by_user, null: true, foreign_key: { to_table: :users, on_delete: :restrict }
      t.references :order, null: true, foreign_key: { on_delete: :restrict }
      t.string :buyer_email_digest, null: false
      t.integer :max_amount_cents, null: false
      t.string :event_state_digest, null: false
      t.string :application_revision, null: false
      t.string :provider_state_digest, null: false
      t.string :platform_configuration_digest, null: false
      t.datetime :expires_at, null: false
      t.datetime :approved_at
      t.datetime :consumed_at
      t.datetime :revoked_at
      t.text :revocation_reason
      t.timestamps
    end

    add_index :live_money_proof_authorizations, :order_id, unique: true,
      where: "order_id IS NOT NULL", name: "idx_live_money_authorizations_unique_order"
    add_index :live_money_proof_authorizations, [:event_id, :created_at],
      name: "idx_live_money_authorizations_timeline"
    add_check_constraint :live_money_proof_authorizations,
      "max_amount_cents > 0 AND max_amount_cents <= 500", name: "live_money_authorizations_amount_valid"
    add_check_constraint :live_money_proof_authorizations,
      "buyer_email_digest ~ '^[0-9a-f]{64}$' AND event_state_digest ~ '^[0-9a-f]{64}$' " \
      "AND provider_state_digest ~ '^[0-9a-f]{64}$' AND platform_configuration_digest ~ '^[0-9a-f]{64}$'",
      name: "live_money_authorizations_digests_valid"
    add_check_constraint :live_money_proof_authorizations,
      "(approved_at IS NULL AND approved_by_user_id IS NULL) OR " \
      "(approved_at IS NOT NULL AND approved_by_user_id IS NOT NULL)",
      name: "live_money_authorizations_approval_valid"
    add_check_constraint :live_money_proof_authorizations,
      "(consumed_at IS NULL AND order_id IS NULL) OR (consumed_at IS NOT NULL AND order_id IS NOT NULL)",
      name: "live_money_authorizations_consumption_valid"
    add_check_constraint :live_money_proof_authorizations,
      "(revoked_at IS NULL AND revocation_reason IS NULL) OR " \
      "(revoked_at IS NOT NULL AND revocation_reason IS NOT NULL AND length(btrim(revocation_reason)) > 0)",
      name: "live_money_authorizations_revocation_valid"

    create_table :live_money_proof_reviews do |t|
      t.references :organization, null: false, foreign_key: { on_delete: :restrict }
      t.references :connected_account, null: false, foreign_key: { on_delete: :restrict }
      t.references :proof_event, null: false, foreign_key: { to_table: :events, on_delete: :restrict }
      t.references :event_day_rehearsal_review, null: false, foreign_key: { on_delete: :restrict }
      t.references :authorization, null: false, foreign_key: {
        to_table: :live_money_proof_authorizations, on_delete: :restrict
      }
      t.references :order, null: false, foreign_key: { on_delete: :restrict }
      t.references :payment, null: false, foreign_key: { on_delete: :restrict }
      t.references :partial_refund, null: false, foreign_key: { to_table: :refunds, on_delete: :restrict }
      t.references :final_refund, null: false, foreign_key: { to_table: :refunds, on_delete: :restrict }
      t.references :initial_settlement, null: false, foreign_key: { to_table: :settlements, on_delete: :restrict }
      t.references :payout, null: false, foreign_key: { on_delete: :restrict }
      t.references :post_payout_settlement, null: false, foreign_key: { to_table: :settlements, on_delete: :restrict }
      t.references :parent_review, null: true, foreign_key: {
        to_table: :live_money_proof_reviews, on_delete: :restrict
      }
      t.references :actor_user, null: false, foreign_key: { to_table: :users, on_delete: :restrict }
      t.integer :decision, null: false
      t.string :evidence_reference, null: false
      t.string :evidence_digest, null: false
      t.string :application_revision, null: false
      t.string :provider_state_digest, null: false
      t.string :platform_configuration_digest, null: false
      t.jsonb :entity_results, null: false, default: {}
      t.jsonb :provider_results, null: false, default: {}
      t.jsonb :reconciliation_results, null: false, default: {}
      t.jsonb :communication_results, null: false, default: {}
      t.jsonb :controls, null: false, default: {}
      t.datetime :effective_at, null: false
      t.datetime :expires_at, null: false
      t.text :reason
      t.timestamps
    end

    add_index :live_money_proof_reviews, [:organization_id, :created_at],
      name: "idx_live_money_proof_reviews_timeline"
    add_index :live_money_proof_reviews, :parent_review_id, unique: true,
      where: "parent_review_id IS NOT NULL AND decision IN (1, 3)",
      name: "idx_live_money_proof_reviews_one_decision"
    add_index :live_money_proof_reviews, :parent_review_id, unique: true,
      where: "parent_review_id IS NOT NULL AND decision = 2",
      name: "idx_live_money_proof_reviews_one_revocation"
    add_check_constraint :live_money_proof_reviews, "decision IN (0, 1, 2, 3)",
      name: "live_money_proof_reviews_decision_valid"
    add_check_constraint :live_money_proof_reviews,
      "evidence_digest ~ '^[0-9a-f]{64}$' AND provider_state_digest ~ '^[0-9a-f]{64}$' " \
      "AND platform_configuration_digest ~ '^[0-9a-f]{64}$'",
      name: "live_money_proof_reviews_digests_valid"
    add_check_constraint :live_money_proof_reviews, "expires_at > effective_at",
      name: "live_money_proof_reviews_window_valid"
    add_check_constraint :live_money_proof_reviews,
      "(decision = 0 AND parent_review_id IS NULL) OR (decision IN (1, 2, 3) AND parent_review_id IS NOT NULL)",
      name: "live_money_proof_reviews_parent_valid"
  end
end
