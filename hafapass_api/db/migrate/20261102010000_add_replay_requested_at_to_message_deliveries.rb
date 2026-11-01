# frozen_string_literal: true

class AddReplayRequestedAtToMessageDeliveries < ActiveRecord::Migration[8.1]
  def change
    # Nullable with no default: a catalog-only change, no table rewrite.
    add_column :message_deliveries, :replay_requested_at, :datetime
  end
end
