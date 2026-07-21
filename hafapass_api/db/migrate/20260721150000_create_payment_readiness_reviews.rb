# frozen_string_literal: true

class CreatePaymentReadinessReviews < ActiveRecord::Migration[8.1]
  def change
    create_table :payment_readiness_reviews do |t|
      t.references :connected_account, null: false, foreign_key: { on_delete: :restrict }
      t.references :parent_review, null: true, foreign_key: {
        to_table: :payment_readiness_reviews, on_delete: :restrict
      }
      t.references :actor_user, null: false, foreign_key: { to_table: :users, on_delete: :restrict }
      t.integer :decision, null: false
      t.string :evidence_reference, null: false
      t.string :evidence_digest, null: false
      t.string :provider_approval_reference, null: false
      t.string :merchant_of_record, null: false
      t.string :fee_tax_schedule_reference, null: false
      t.string :liability_schedule_reference, null: false
      t.jsonb :controls, null: false, default: {}
      t.datetime :effective_at, null: false
      t.datetime :expires_at, null: false
      t.text :reason
      t.timestamps
    end

    add_index :payment_readiness_reviews, :parent_review_id, unique: true,
      where: "parent_review_id IS NOT NULL AND decision = 1",
      name: "idx_payment_reviews_one_approval"
    add_index :payment_readiness_reviews, :parent_review_id, unique: true,
      where: "parent_review_id IS NOT NULL AND decision = 2",
      name: "idx_payment_reviews_one_revocation"
    add_index :payment_readiness_reviews, [:connected_account_id, :created_at],
      name: "idx_payment_reviews_account_timeline"
    add_check_constraint :payment_readiness_reviews, "decision IN (0, 1, 2)",
      name: "payment_readiness_reviews_decision_valid"
    add_check_constraint :payment_readiness_reviews,
      "evidence_digest ~ '^[0-9a-f]{64}$'",
      name: "payment_readiness_reviews_digest_valid"
    add_check_constraint :payment_readiness_reviews,
      "merchant_of_record IN ('platform', 'organizer', 'provider_managed')",
      name: "payment_readiness_reviews_merchant_valid"
    add_check_constraint :payment_readiness_reviews, "expires_at > effective_at",
      name: "payment_readiness_reviews_window_valid"
    add_check_constraint :payment_readiness_reviews,
      "(decision = 0 AND parent_review_id IS NULL) OR (decision IN (1, 2) AND parent_review_id IS NOT NULL)",
      name: "payment_readiness_reviews_parent_valid"

    reversible do |direction|
      direction.up do
        execute <<~SQL.squish
          UPDATE connected_accounts
          SET status = 2,
              requirements_due = CASE
                WHEN requirements_due @> '["independent_readiness_approval"]'::jsonb THEN requirements_due
                ELSE requirements_due || '["independent_readiness_approval"]'::jsonb
              END,
              updated_at = CURRENT_TIMESTAMP
          WHERE status = 3
        SQL
      end
    end
  end
end
