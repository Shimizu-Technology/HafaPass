# frozen_string_literal: true

module Operations
  class EmbeddedReadiness
    HEARTBEAT_WINDOW = 90.seconds

    def self.processes
      return SolidQueue::Process.none unless ApplicationRevision.configured?

      scope = SolidQueue::Process.where("last_heartbeat_at > ?", HEARTBEAT_WINDOW.ago)
        .where("metadata::jsonb ->> 'application_revision' = ?", ApplicationRevision.current)
        .where("metadata::jsonb ->> 'runtime_profile' = ?", RuntimeConfiguration.profile)
      scope = scope.where("metadata::jsonb ->> 'runtime_instance' = ?", RuntimeConfiguration.instance_id) if RuntimeConfiguration.embedded?
      scope
    end

    def self.worker
      count = processes.where(kind: "Worker").count
      stale = SolidQueue::ClaimedExecution.where("created_at < ?", 5.minutes.ago).exists? ||
        SolidQueue::ReadyExecution.where("created_at < ?", 5.minutes.ago).exists?
      { ready: count.positive? && !stale, status: stale ? "execution_stalled" : (count.positive? ? "active" : "no_active_process"), processes: count,
        adapter: "solid_queue", profile: RuntimeConfiguration.profile }
    end

    def self.scheduler
      actors = processes.where(kind: %w[Dispatcher Scheduler]).group(:kind).count
      ready = actors.fetch("Dispatcher", 0).positive? && actors.fetch("Scheduler", 0).positive?
      required = %w[inventory_expiry seat_expiry runtime_recovery stripe_fee_recovery marketplace_retention runtime_retention]
      configured = SolidQueue::RecurringTask.static.where(key: required).count == required.length
      recent = %w[inventory_expiry seat_expiry runtime_recovery].all? { |key| successful_since?(key, 3.minutes.ago) } &&
        successful_since?("stripe_fee_recovery", 7.minutes.ago)
      overdue = Order.pending.where("expires_at < ?", 3.minutes.ago).exists? ||
        SeatHoldSession.where(status: [:active, :claimed]).where("expires_at < ?", 3.minutes.ago).exists?
      healthy = ready && configured && recent && !overdue
      { ready: healthy, status: healthy ? "active" : "scheduler_unavailable",
        dispatcher_processes: actors.fetch("Dispatcher", 0), scheduler_processes: actors.fetch("Scheduler", 0),
        recurring_tasks_configured: configured, recent_execution_progress: recent, overdue_inventory: overdue }
    end

    def self.successful_since?(key, time)
      RuntimeExecution.where(task_key: key, application_revision: ApplicationRevision.current)
        .where("last_succeeded_at > ?", time).exists?
    end
  end
end
