# frozen_string_literal: true

class RecordRuntimeExecutionProgress < ActiveRecord::Migration[8.0]
  def change
    create_table :runtime_executions, id: false do |t|
      t.string :task_key, null: false
      t.string :application_revision, null: false
      t.datetime :last_succeeded_at, null: false
    end
    add_index :runtime_executions, [:task_key, :application_revision], unique: true
  end
end
