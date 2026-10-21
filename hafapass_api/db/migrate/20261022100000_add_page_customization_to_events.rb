class AddPageCustomizationToEvents < ActiveRecord::Migration[8.0]
  def change
    add_column :events, :page_customization, :jsonb, null: false, default: {}
  end
end
