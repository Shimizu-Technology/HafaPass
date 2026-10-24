# frozen_string_literal: true

class AddManualPayoutReviewSnapshots < ActiveRecord::Migration[8.0]
  def change
    add_column :payment_readiness_reviews, :review_kind, :string, null: false, default: "provider_evidence"
    add_column :payment_readiness_reviews, :reviewed_snapshot, :jsonb, null: false, default: {}
    add_column :connected_accounts, :bank_account_number, :text
  end
end
