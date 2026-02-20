# frozen_string_literal: true

class AddSingletonGuardToSiteSettings < ActiveRecord::Migration[8.1]
  def change
    # Add a singleton_guard column that's always 0, with a unique index.
    # This guarantees only one row can ever exist in site_settings.
    add_column :site_settings, :singleton_guard, :integer, default: 0, null: false
    add_index :site_settings, :singleton_guard, unique: true
  end
end
