# Retired public link names. Each row keeps an old /events/:slug or
# /venues/:slug URL resolving to the record that used to own it, so renaming
# an event or venue never breaks links already shared on social media, in
# emails, or on posters. custom_slug marks events whose organizer chose the
# link name, which stops a draft's link from following later title edits.
class CreateSlugRedirects < ActiveRecord::Migration[8.1]
  def change
    create_table :event_slug_redirects do |t|
      t.references :event, null: false, foreign_key: true
      t.string :slug, null: false
      t.timestamps
    end
    add_index :event_slug_redirects, :slug, unique: true

    create_table :venue_slug_redirects do |t|
      t.references :venue, null: false, foreign_key: true
      t.string :slug, null: false
      t.timestamps
    end
    add_index :venue_slug_redirects, :slug, unique: true

    add_column :events, :custom_slug, :boolean, default: false, null: false
  end
end
