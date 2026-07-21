# frozen_string_literal: true

class CreatePilotValidationReviews < ActiveRecord::Migration[8.1]
  def change
    create_table :pilot_validation_reviews do |t|
      t.references :event, null: false, foreign_key: { on_delete: :restrict }
      t.references :pilot_readiness_review, null: false, foreign_key: { on_delete: :restrict }
      t.references :parent_review, null: true, foreign_key: {
        to_table: :pilot_validation_reviews, on_delete: :restrict
      }
      t.references :actor_user, null: false, foreign_key: { to_table: :users, on_delete: :restrict }
      t.integer :decision, null: false
      t.string :evidence_reference, null: false
      t.string :evidence_digest, null: false
      t.string :event_state_digest, null: false
      t.string :application_revision, null: false
      t.jsonb :device_matrix, null: false, default: {}
      t.jsonb :buyer_flows, null: false, default: {}
      t.jsonb :organizer_flows, null: false, default: {}
      t.jsonb :accessibility_results, null: false, default: {}
      t.jsonb :load_results, null: false, default: {}
      t.jsonb :controls, null: false, default: {}
      t.datetime :effective_at, null: false
      t.datetime :expires_at, null: false
      t.text :reason
      t.timestamps
    end

    add_index :pilot_validation_reviews, [:event_id, :created_at], name: "idx_pilot_validation_reviews_timeline"
    add_index :pilot_validation_reviews, :parent_review_id, unique: true,
      where: "parent_review_id IS NOT NULL AND decision IN (1, 3)",
      name: "idx_pilot_validation_reviews_one_decision"
    add_index :pilot_validation_reviews, :parent_review_id, unique: true,
      where: "parent_review_id IS NOT NULL AND decision = 2",
      name: "idx_pilot_validation_reviews_one_revocation"
    add_check_constraint :pilot_validation_reviews, "decision IN (0, 1, 2, 3)",
      name: "pilot_validation_reviews_decision_valid"
    add_check_constraint :pilot_validation_reviews,
      "evidence_digest ~ '^[0-9a-f]{64}$' AND event_state_digest ~ '^[0-9a-f]{64}$'",
      name: "pilot_validation_reviews_digests_valid"
    add_check_constraint :pilot_validation_reviews, "expires_at > effective_at",
      name: "pilot_validation_reviews_window_valid"
    add_check_constraint :pilot_validation_reviews,
      "(decision = 0 AND parent_review_id IS NULL) OR (decision IN (1, 2, 3) AND parent_review_id IS NOT NULL)",
      name: "pilot_validation_reviews_parent_valid"
  end
end
