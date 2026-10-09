class CreateImageUploadReceipts < ActiveRecord::Migration[8.0]
  def change
    create_table :image_upload_receipts do |t|
      t.references :user, null: false, foreign_key: { on_delete: :cascade }
      t.references :organization, null: false, foreign_key: { on_delete: :cascade }
      t.references :event, foreign_key: { on_delete: :cascade }
      t.string :source_key, null: false
      t.string :final_key, null: false
      t.string :public_url
      t.datetime :completed_at
      t.timestamps
    end
    add_index :image_upload_receipts, :source_key, unique: true
  end
end
