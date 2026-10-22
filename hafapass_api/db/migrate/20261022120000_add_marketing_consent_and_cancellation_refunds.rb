class AddMarketingConsentAndCancellationRefunds < ActiveRecord::Migration[8.0]
  def change
    add_column :orders, :marketing_opt_in, :boolean, null: false, default: false
    add_column :site_settings, :business_mailing_address, :text

    create_table :marketing_unsubscribes do |t|
      t.references :organization, null: false, foreign_key: true
      t.string :email, null: false
      t.datetime :unsubscribed_at, null: false
      t.timestamps
    end
    add_index :marketing_unsubscribes, [:organization_id, :email], unique: true

    create_table :event_cancellation_refund_runs do |t|
      t.references :event, null: false, foreign_key: true, index: { unique: true }
      t.references :started_by, null: false, foreign_key: { to_table: :users }
      t.integer :status, null: false, default: 0
      t.datetime :completed_at
      t.timestamps
    end
    create_table :event_cancellation_refund_items do |t|
      t.references :event_cancellation_refund_run, null: false, foreign_key: true, index: { name: "index_cancellation_refund_items_on_run" }
      t.references :order, null: false, foreign_key: true, index: { unique: true }
      t.integer :status, null: false, default: 0
      t.integer :amount_cents, null: false, default: 0
      t.integer :retry_generation, null: false, default: 0
      t.text :last_error
      t.timestamps
    end
  end
end
