class CreateOrganizerSalesExportRequests < ActiveRecord::Migration[8.0]
  def change
    create_table :organizer_sales_export_requests do |t|
      t.references :event, null: false, foreign_key: true
      t.references :actor_user, null: false, foreign_key: { to_table: :users }
      t.jsonb :filters, null: false, default: {}
      t.jsonb :columns, null: false, default: []
      t.integer :row_count, null: false, default: 0
      t.string :status, null: false, default: "pending"
      t.string :storage_key
      t.datetime :expires_at
      t.timestamps
    end
    add_index :organizer_sales_export_requests, [:actor_user_id, :created_at],
      name: "index_sales_exports_on_actor_and_created_at"
  end
end
