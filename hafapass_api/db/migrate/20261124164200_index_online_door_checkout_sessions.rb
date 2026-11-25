# frozen_string_literal: true

class IndexOnlineDoorCheckoutSessions < ActiveRecord::Migration[8.1]
  disable_ddl_transaction!

  def change
    add_index :payments, :stripe_checkout_session_id, unique: true, algorithm: :concurrently,
      where: "stripe_checkout_session_id IS NOT NULL"
  end
end
