# frozen_string_literal: true

class SeparateOrganizerSalesSuspension < ActiveRecord::Migration[8.0]
  def change
    add_column :events, :organizer_sales_suspended_at, :datetime
    add_column :events, :organizer_sales_suspension_reason, :text
  end
end
