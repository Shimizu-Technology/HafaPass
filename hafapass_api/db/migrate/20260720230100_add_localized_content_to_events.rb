# frozen_string_literal: true

class AddLocalizedContentToEvents < ActiveRecord::Migration[8.1]
  def change
    add_column :events, :localized_content, :jsonb, null: false, default: {}
  end
end
