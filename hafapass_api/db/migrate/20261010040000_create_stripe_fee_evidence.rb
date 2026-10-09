class CreateStripeFeeEvidence < ActiveRecord::Migration[8.0]
  def change
    create_table :stripe_fee_evidences do |t|
      t.references :payment, null: false, foreign_key: true, index: { unique: true }
      t.references :fee_component, foreign_key: true, index: { unique: true }
      t.string :status, null: false, default: "pending"
      t.string :context_digest, null: false
      t.string :provider_charge_id
      t.string :provider_balance_transaction_id
      t.string :evidence_digest
      t.integer :amount_cents
      t.integer :fee_cents
      t.integer :net_cents
      t.string :currency
      t.string :balance_status
      t.jsonb :fee_details, null: false, default: []
      t.integer :attempts, null: false, default: 0
      t.string :last_error_code
      t.datetime :next_attempt_at
      t.datetime :verified_at
      t.timestamps
    end
    add_index :stripe_fee_evidences, [:context_digest, :provider_balance_transaction_id], unique: true,
      where: "provider_balance_transaction_id IS NOT NULL", name: "idx_stripe_fee_provider_identity"
    add_check_constraint :stripe_fee_evidences, "status IN ('pending', 'verified', 'review_required')", name: "stripe_fee_evidence_status"
  end
end
