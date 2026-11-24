# frozen_string_literal: true

# Two-connection race used by the payout lock-order specs. One connection plays
# an order lifecycle step: it holds the event row FOR NO KEY UPDATE, waits until
# the other connection is blocked behind it, then takes the organization
# FOR KEY SHARE that its audit-log insert's foreign key needs. The block runs on
# the second connection. On a lock order that takes the organization FOR UPDATE
# and then the event, PostgreSQL reports a deadlock.
#
# Every helper thread returns its connection, both threads are joined (or
# killed) before returning, and session settings are reset, so later
# concurrency specs in the same process get a full connection pool.
module LockRaceHelpers
  RACE_LOCK_TIMEOUT = "8s"
  RACE_DEADLINE_SECONDS = 15

  def race_against_event_audit(event:, organization:, &work)
    event_held = Queue.new
    worker_pid = Queue.new
    results = Queue.new
    holder = Thread.new do
      ActiveRecord::Base.connection_pool.with_connection(prevent_permanent_checkout: true) do |connection|
        connection.transaction do
          connection.execute("SET LOCAL lock_timeout = '#{RACE_LOCK_TIMEOUT}'")
          connection.select_value("SELECT id FROM events WHERE id = #{event.id.to_i} FOR NO KEY UPDATE")
          event_held << true
          pid = worker_pid.pop(timeout: RACE_DEADLINE_SECONDS) || raise("worker never started")
          deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + RACE_DEADLINE_SECONDS
          until connection.select_value("SELECT cardinality(pg_blocking_pids(#{pid.to_i}))").to_i.positive?
            raise "worker never blocked on the event" if Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline

            sleep 0.02
          end
          # What an AuditLog (or any organization foreign key) insert takes.
          connection.select_value("SELECT id FROM organizations WHERE id = #{organization.id.to_i} FOR KEY SHARE")
        end
      end
      results << [:holder, :committed]
    rescue StandardError => error
      results << [:holder, error]
    ensure
      ActiveRecord::Base.connection_pool.release_connection
    end
    worker = Thread.new do
      ActiveRecord::Base.connection_pool.with_connection(prevent_permanent_checkout: true) do |connection|
        worker_pid << connection.select_value("SELECT pg_backend_pid()")
        event_held.pop(timeout: RACE_DEADLINE_SECONDS) || raise("holder never locked the event")
        connection.execute("SET lock_timeout = '#{RACE_LOCK_TIMEOUT}'")
        begin
          results << [:worker, work.call]
        ensure
          connection.execute("RESET lock_timeout")
        end
      end
    rescue StandardError => error
      results << [:worker, error]
    ensure
      ActiveRecord::Base.connection_pool.release_connection
    end
    [holder, worker].each { |thread| thread.join(RACE_DEADLINE_SECONDS * 2) }
    Array.new(2) { results.pop(timeout: 1) }.compact.to_h
  ensure
    [holder, worker].compact.each do |thread|
      thread.kill if thread.alive?
      thread.join(5)
    end
  end
end

RSpec.configure { |config| config.include LockRaceHelpers }
