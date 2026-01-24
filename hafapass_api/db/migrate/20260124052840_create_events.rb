class CreateEvents < ActiveRecord::Migration[8.1]
  def change
    create_table :events do |t|
      t.references :organizer_profile, null: false, foreign_key: true
      t.string :title, null: false
      t.string :slug, null: false
      t.text :description
      t.string :short_description
      t.string :cover_image_url
      t.string :venue_name
      t.string :venue_address
      t.string :venue_city
      t.datetime :starts_at
      t.datetime :ends_at
      t.datetime :doors_open_at
      t.string :timezone, default: "Pacific/Guam"
      t.integer :status, default: 0
      t.integer :category, default: 5
      t.integer :age_restriction, default: 0
      t.integer :max_capacity
      t.boolean :is_featured, default: false
      t.datetime :published_at

      t.timestamps
    end

    add_index :events, :slug, unique: true
    add_index :events, :status
    add_index :events, :starts_at
  end
end
