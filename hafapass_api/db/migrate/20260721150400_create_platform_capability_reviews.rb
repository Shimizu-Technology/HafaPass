# frozen_string_literal: true

class CreatePlatformCapabilityReviews < ActiveRecord::Migration[8.1]
  def change
    create_table :platform_capability_reviews do |t|
      t.references :parent_review, null: true, foreign_key: {
        to_table: :platform_capability_reviews, on_delete: :restrict
      }
      t.references :actor_user, null: false, foreign_key: { to_table: :users, on_delete: :restrict }
      t.string :capability, null: false
      t.integer :decision, null: false
      t.string :evidence_reference, null: false
      t.string :evidence_digest, null: false
      t.string :configuration_digest, null: false
      t.jsonb :controls, null: false, default: {}
      t.datetime :effective_at, null: false
      t.datetime :expires_at, null: false
      t.text :reason
      t.timestamps
    end

    add_index :platform_capability_reviews, [:capability, :created_at],
      name: "idx_platform_capability_reviews_timeline"
    add_index :platform_capability_reviews, :parent_review_id, unique: true,
      where: "parent_review_id IS NOT NULL AND decision = 1",
      name: "idx_platform_capability_reviews_one_approval"
    add_index :platform_capability_reviews, :parent_review_id, unique: true,
      where: "parent_review_id IS NOT NULL AND decision = 2",
      name: "idx_platform_capability_reviews_one_revocation"
    add_index :platform_capability_reviews, :parent_review_id, unique: true,
      where: "parent_review_id IS NOT NULL AND decision = 3",
      name: "idx_platform_capability_reviews_one_rejection"
    add_check_constraint :platform_capability_reviews, "decision IN (0, 1, 2, 3)",
      name: "platform_capability_reviews_decision_valid"
    add_check_constraint :platform_capability_reviews,
      "capability IN ('stripe_live', 'resend_production', 'apple_wallet', 'google_wallet', 'clover_card_present', 'policy_register')",
      name: "platform_capability_reviews_capability_valid"
    add_check_constraint :platform_capability_reviews,
      "evidence_digest ~ '^[0-9a-f]{64}$' AND configuration_digest ~ '^[0-9a-f]{64}$'",
      name: "platform_capability_reviews_digests_valid"
    add_check_constraint :platform_capability_reviews, "expires_at > effective_at",
      name: "platform_capability_reviews_window_valid"
    add_check_constraint :platform_capability_reviews,
      "(decision = 0 AND parent_review_id IS NULL) OR (decision IN (1, 2, 3) AND parent_review_id IS NOT NULL)",
      name: "platform_capability_reviews_parent_valid"
  end
end
