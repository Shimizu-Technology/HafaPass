# frozen_string_literal: true

class AddOnlineDoorCheckout < ActiveRecord::Migration[8.1]
  def change
    add_column :events, :online_door_card_enabled, :boolean, default: false, null: false
    add_column :payments, :stripe_checkout_session_id, :string
    add_column :payments, :stripe_checkout_url, :text
  end
end
