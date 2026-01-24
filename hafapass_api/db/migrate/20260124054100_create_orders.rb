class CreateOrders < ActiveRecord::Migration[8.1]
  def change
    create_table :orders do |t|
      t.references :user, null: true, foreign_key: true
      t.references :event, null: false, foreign_key: true
      t.integer :status, null: false, default: 0
      t.integer :subtotal_cents, null: false, default: 0
      t.integer :service_fee_cents, null: false, default: 0
      t.integer :total_cents, null: false, default: 0
      t.string :buyer_email
      t.string :buyer_name
      t.string :buyer_phone
      t.string :stripe_payment_intent_id
      t.datetime :completed_at

      t.timestamps
    end
  end
end
