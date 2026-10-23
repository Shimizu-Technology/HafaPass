# frozen_string_literal: true

class TrackCampaignExecutionAuthority < ActiveRecord::Migration[8.0]
  def change
    add_reference :communication_campaigns, :scheduled_by_user, foreign_key: { to_table: :users }
    add_reference :communication_campaigns, :sent_by_user, foreign_key: { to_table: :users }
    add_column :communication_campaigns, :last_error, :text
  end
end
