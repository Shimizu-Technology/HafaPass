# frozen_string_literal: true

class VersionConnectedAccountReadiness < ActiveRecord::Migration[8.1]
  def change
    add_column :connected_accounts, :readiness_revision, :integer, null: false, default: 1
    add_check_constraint :connected_accounts, "readiness_revision > 0",
      name: "connected_accounts_readiness_revision_positive"
  end
end
