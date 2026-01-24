class CreateOrganizerProfiles < ActiveRecord::Migration[8.1]
  def change
    create_table :organizer_profiles do |t|
      t.references :user, null: false, foreign_key: true
      t.string :business_name
      t.text :business_description
      t.string :logo_url
      t.string :stripe_account_id
      t.boolean :is_ambros_partner, default: false

      t.timestamps
    end
  end
end
