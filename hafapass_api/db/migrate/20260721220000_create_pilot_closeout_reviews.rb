# frozen_string_literal: true

class CreatePilotCloseoutReviews < ActiveRecord::Migration[8.1]
  def change
    create_table :pilot_closeout_reviews do |t|
      t.references :event, null: false, foreign_key: { on_delete: :restrict }
      t.references :live_pilot_run, null: false, foreign_key: { on_delete: :restrict }
      t.references :parent_review, null: true,
        foreign_key: { to_table: :pilot_closeout_reviews, on_delete: :restrict }
      t.references :actor_user, null: false, foreign_key: { to_table: :users, on_delete: :restrict }
      t.integer :decision, null: false
      t.integer :expansion_decision, null: false
      t.string :evidence_reference, null: false
      t.string :evidence_digest, null: false
      t.string :local_state_digest, null: false
      t.string :application_revision, null: false
      t.jsonb :local_metrics, null: false, default: {}
      t.jsonb :outcome_metrics, null: false, default: {}
      t.jsonb :reconciliation_results, null: false, default: {}
      t.jsonb :cleanup_results, null: false, default: {}
      t.jsonb :evidence_references, null: false, default: {}
      t.jsonb :retrospective_actions, null: false, default: []
      t.jsonb :expansion_scope, null: false, default: {}
      t.datetime :signed_at, null: false
      t.text :reason
      t.timestamps
    end

    add_index :pilot_closeout_reviews, [:event_id, :created_at], name: "idx_pilot_closeout_timeline"
    add_index :pilot_closeout_reviews, [:live_pilot_run_id, :created_at], name: "idx_pilot_closeout_run_timeline"
    add_index :pilot_closeout_reviews, :parent_review_id, unique: true,
      where: "parent_review_id IS NOT NULL AND decision = 1", name: "idx_pilot_closeout_one_approval"
    add_index :pilot_closeout_reviews, :parent_review_id, unique: true,
      where: "parent_review_id IS NOT NULL AND decision = 2", name: "idx_pilot_closeout_one_revocation"
    add_index :pilot_closeout_reviews, :parent_review_id, unique: true,
      where: "parent_review_id IS NOT NULL AND decision = 3", name: "idx_pilot_closeout_one_rejection"
    add_check_constraint :pilot_closeout_reviews, "decision IN (0, 1, 2, 3)",
      name: "pilot_closeout_decision_valid"
    add_check_constraint :pilot_closeout_reviews, "expansion_decision IN (0, 1, 2)",
      name: "pilot_closeout_expansion_valid"
    add_check_constraint :pilot_closeout_reviews,
      "(decision = 0 AND parent_review_id IS NULL) OR (decision IN (1, 2, 3) AND parent_review_id IS NOT NULL)",
      name: "pilot_closeout_parent_valid"
    add_check_constraint :pilot_closeout_reviews,
      "evidence_digest ~ '^[0-9a-f]{64}$' AND local_state_digest ~ '^[0-9a-f]{64}$'",
      name: "pilot_closeout_digests_valid"
  end
end
