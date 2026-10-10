# frozen_string_literal: true

class RuntimeExecution < ApplicationRecord
  self.primary_key = [:task_key, :application_revision]

  TASKS = { "ExpireInventoryHoldsJob" => "inventory_expiry", "ExpireSeatHoldsJob" => "seat_expiry",
    "RuntimeRecoveryJob" => "runtime_recovery", "SweepPendingStripeFeesJob" => "stripe_fee_recovery" }.freeze

  def self.record!(job)
    key = TASKS[job.class.name]
    return unless key && RuntimeConfiguration.solid_queue?

    upsert({ task_key: key, application_revision: ApplicationRevision.current,
      last_succeeded_at: Time.current }, unique_by: [:task_key, :application_revision])
  end
end
