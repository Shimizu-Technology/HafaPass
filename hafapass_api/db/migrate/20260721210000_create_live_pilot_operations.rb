# frozen_string_literal: true

class CreateLivePilotOperations < ActiveRecord::Migration[8.1]
  def change
    create_table :live_pilot_reviews do |t|
      t.references :event, null: false, foreign_key: { on_delete: :restrict }
      t.references :event_day_rehearsal_review, null: false, foreign_key: { on_delete: :restrict }
      t.references :live_money_proof_review, null: true, foreign_key: { on_delete: :restrict }
      t.references :parent_review, null: true, foreign_key: { to_table: :live_pilot_reviews, on_delete: :restrict }
      t.references :actor_user, null: false, foreign_key: { to_table: :users, on_delete: :restrict }
      t.integer :decision, null: false
      t.string :evidence_reference, null: false
      t.string :evidence_digest, null: false
      t.string :event_state_digest, null: false
      t.string :application_revision, null: false
      t.integer :inventory_cap, null: false
      t.jsonb :support_coverage, null: false, default: {}
      t.jsonb :assignments, null: false, default: {}
      t.jsonb :thresholds, null: false, default: {}
      t.jsonb :controls, null: false, default: {}
      t.datetime :effective_at, null: false
      t.datetime :expires_at, null: false
      t.text :reason
      t.timestamps
    end
    add_index :live_pilot_reviews, [:event_id, :created_at], name: "idx_live_pilot_reviews_timeline"
    add_index :live_pilot_reviews, :parent_review_id, unique: true,
      where: "parent_review_id IS NOT NULL AND decision = 1", name: "idx_live_pilot_reviews_one_approval"
    add_index :live_pilot_reviews, :parent_review_id, unique: true,
      where: "parent_review_id IS NOT NULL AND decision = 2", name: "idx_live_pilot_reviews_one_revocation"
    add_index :live_pilot_reviews, :parent_review_id, unique: true,
      where: "parent_review_id IS NOT NULL AND decision = 3", name: "idx_live_pilot_reviews_one_rejection"
    add_check_constraint :live_pilot_reviews, "decision IN (0, 1, 2, 3)",
      name: "live_pilot_reviews_decision_valid"
    add_check_constraint :live_pilot_reviews,
      "(decision = 0 AND parent_review_id IS NULL) OR (decision IN (1, 2, 3) AND parent_review_id IS NOT NULL)",
      name: "live_pilot_reviews_parent_valid"
    add_check_constraint :live_pilot_reviews, "inventory_cap > 0 AND inventory_cap <= 250",
      name: "live_pilot_reviews_inventory_cap_valid"
    add_check_constraint :live_pilot_reviews,
      "evidence_digest ~ '^[0-9a-f]{64}$' AND event_state_digest ~ '^[0-9a-f]{64}$'",
      name: "live_pilot_reviews_digests_valid"
    add_check_constraint :live_pilot_reviews, "expires_at > effective_at",
      name: "live_pilot_reviews_window_valid"

    create_table :live_pilot_runs do |t|
      t.references :event, null: false, foreign_key: { on_delete: :restrict }
      t.references :live_pilot_review, null: false, foreign_key: { on_delete: :restrict }, index: { unique: true }
      t.references :started_by_user, null: false, foreign_key: { to_table: :users, on_delete: :restrict }
      t.references :completed_by_user, null: true, foreign_key: { to_table: :users, on_delete: :restrict }
      t.integer :status, null: false, default: 0
      t.datetime :started_at, null: false
      t.datetime :paused_at
      t.datetime :completed_at
      t.datetime :aborted_at
      t.text :pause_reason
      t.text :abort_reason
      t.string :completion_evidence_reference
      t.string :completion_evidence_digest
      t.jsonb :completion_results, null: false, default: {}
      t.timestamps
    end
    add_index :live_pilot_runs, [:event_id, :created_at], name: "idx_live_pilot_runs_timeline"
    add_index :live_pilot_runs, :event_id, unique: true, where: "status IN (0, 1)",
      name: "idx_live_pilot_runs_one_open"
    add_check_constraint :live_pilot_runs, "status IN (0, 1, 2, 3)", name: "live_pilot_runs_status_valid"
    add_check_constraint :live_pilot_runs,
      "completion_evidence_digest IS NULL OR completion_evidence_digest ~ '^[0-9a-f]{64}$'",
      name: "live_pilot_runs_completion_digest_valid"

    create_table :live_pilot_run_actions do |t|
      t.references :live_pilot_run, null: false, foreign_key: { on_delete: :restrict }
      t.references :event, null: false, foreign_key: { on_delete: :restrict }
      t.references :actor_user, null: true, foreign_key: { to_table: :users, on_delete: :restrict }
      t.integer :kind, null: false
      t.jsonb :details, null: false, default: {}
      t.datetime :occurred_at, null: false
      t.timestamps
    end
    add_index :live_pilot_run_actions, [:live_pilot_run_id, :occurred_at], name: "idx_live_pilot_actions_timeline"
    add_check_constraint :live_pilot_run_actions, "kind IN (0, 1, 2, 3, 4)",
      name: "live_pilot_run_actions_kind_valid"

    create_table :live_pilot_incidents do |t|
      t.references :live_pilot_run, null: false, foreign_key: { on_delete: :restrict }
      t.references :event, null: false, foreign_key: { on_delete: :restrict }
      t.references :parent_incident, null: true, foreign_key: { to_table: :live_pilot_incidents, on_delete: :restrict }
      t.references :actor_user, null: false, foreign_key: { to_table: :users, on_delete: :restrict }
      t.integer :action, null: false
      t.integer :severity, null: false
      t.string :category, null: false
      t.text :summary, null: false
      t.string :evidence_reference, null: false
      t.string :evidence_digest, null: false
      t.datetime :occurred_at, null: false
      t.timestamps
    end
    add_index :live_pilot_incidents, [:live_pilot_run_id, :occurred_at], name: "idx_live_pilot_incidents_timeline"
    add_index :live_pilot_incidents, :parent_incident_id, unique: true,
      where: "parent_incident_id IS NOT NULL AND action = 1", name: "idx_live_pilot_incidents_one_resolution"
    add_check_constraint :live_pilot_incidents, "action IN (0, 1)", name: "live_pilot_incidents_action_valid"
    add_check_constraint :live_pilot_incidents, "severity IN (0, 1, 2, 3)", name: "live_pilot_incidents_severity_valid"
    add_check_constraint :live_pilot_incidents, "evidence_digest ~ '^[0-9a-f]{64}$'",
      name: "live_pilot_incidents_digest_valid"
    add_check_constraint :live_pilot_incidents,
      "(action = 0 AND parent_incident_id IS NULL) OR (action = 1 AND parent_incident_id IS NOT NULL)",
      name: "live_pilot_incidents_parent_valid"

    create_table :live_pilot_metric_snapshots do |t|
      t.references :live_pilot_run, null: false, foreign_key: { on_delete: :restrict }
      t.references :event, null: false, foreign_key: { on_delete: :restrict }
      t.references :recorded_by_user, null: false, foreign_key: { to_table: :users, on_delete: :restrict }
      t.jsonb :local_metrics, null: false, default: {}
      t.jsonb :external_metrics, null: false, default: {}
      t.jsonb :breached_thresholds, null: false, default: {}
      t.string :evidence_reference, null: false
      t.string :evidence_digest, null: false
      t.datetime :observed_at, null: false
      t.timestamps
    end
    add_index :live_pilot_metric_snapshots, [:live_pilot_run_id, :observed_at],
      name: "idx_live_pilot_metrics_timeline"
    add_check_constraint :live_pilot_metric_snapshots, "evidence_digest ~ '^[0-9a-f]{64}$'",
      name: "live_pilot_metrics_digest_valid"
  end
end
