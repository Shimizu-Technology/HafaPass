# frozen_string_literal: true

class BindPaymentReviewsToProviderState < ActiveRecord::Migration[8.1]
  def change
    add_column :payment_readiness_reviews, :provider_state_digest, :string
    change_column_null :payment_readiness_reviews, :provider_state_digest, false
    add_check_constraint :payment_readiness_reviews,
      "provider_state_digest ~ '^[0-9a-f]{64}$'",
      name: "payment_readiness_reviews_provider_state_digest_valid"
  end
end
