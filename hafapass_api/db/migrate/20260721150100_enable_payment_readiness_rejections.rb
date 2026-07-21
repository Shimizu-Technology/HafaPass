# frozen_string_literal: true

class EnablePaymentReadinessRejections < ActiveRecord::Migration[8.1]
  def up
    remove_check_constraint :payment_readiness_reviews, name: "payment_readiness_reviews_decision_valid"
    remove_check_constraint :payment_readiness_reviews, name: "payment_readiness_reviews_parent_valid"
    add_index :payment_readiness_reviews, :parent_review_id, unique: true,
      where: "parent_review_id IS NOT NULL AND decision = 3",
      name: "idx_payment_reviews_one_rejection"
    add_check_constraint :payment_readiness_reviews, "decision IN (0, 1, 2, 3)",
      name: "payment_readiness_reviews_decision_valid"
    add_check_constraint :payment_readiness_reviews,
      "(decision = 0 AND parent_review_id IS NULL) OR (decision IN (1, 2, 3) AND parent_review_id IS NOT NULL)",
      name: "payment_readiness_reviews_parent_valid"
  end

  def down
    remove_check_constraint :payment_readiness_reviews, name: "payment_readiness_reviews_parent_valid"
    remove_check_constraint :payment_readiness_reviews, name: "payment_readiness_reviews_decision_valid"
    remove_index :payment_readiness_reviews, name: "idx_payment_reviews_one_rejection"
    add_check_constraint :payment_readiness_reviews, "decision IN (0, 1, 2)",
      name: "payment_readiness_reviews_decision_valid"
    add_check_constraint :payment_readiness_reviews,
      "(decision = 0 AND parent_review_id IS NULL) OR (decision IN (1, 2) AND parent_review_id IS NOT NULL)",
      name: "payment_readiness_reviews_parent_valid"
  end
end
