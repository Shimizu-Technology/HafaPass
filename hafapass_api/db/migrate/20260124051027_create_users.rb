class CreateUsers < ActiveRecord::Migration[8.1]
  def change
    create_table :users do |t|
      t.string :clerk_id, null: false
      t.string :email
      t.string :first_name
      t.string :last_name
      t.string :phone
      t.integer :role, default: 0, null: false

      t.timestamps
    end

    add_index :users, :clerk_id, unique: true
  end
end
