# frozen_string_literal: true

class CompleteRegistrationResponseSnapshots < ActiveRecord::Migration[8.1]
  def change
    add_column :registration_responses, :required_snapshot, :boolean, null: false, default: false
    add_column :registration_responses, :options_snapshot, :jsonb, null: false, default: []
  end
end
