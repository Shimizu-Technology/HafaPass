# frozen_string_literal: true

class CreateRuntimeAlertStates < ActiveRecord::Migration[8.1]
  def change
    # One row per operational alert signal: the count last seen and when it
    # last raised a Sentry alert, so a standing count isn't re-alerted every run.
    create_table :runtime_alert_states, id: :string, primary_key: :signal do |t|
      t.integer :last_count, null: false, default: 0
      t.datetime :last_alerted_at
      t.datetime :updated_at, null: false
    end
  end
end
