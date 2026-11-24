# This configuration file will be evaluated by Puma. The top-level methods that
# are invoked here are part of Puma's configuration DSL. For more information
# about methods provided by the DSL, see https://puma.io/puma/Puma/DSL.html.
#
# Puma starts a configurable number of processes (workers) and each process
# serves each request in a thread from an internal thread pool.
#
# You can control the number of workers using ENV["WEB_CONCURRENCY"]. You
# should only set this value when you want to run 2 or more workers. The
# default is already 1. You can set it to `auto` to automatically start a worker
# for each available processor.
#
# The ideal number of threads per worker depends both on how much time the
# application spends waiting for IO operations and on how much you wish to
# prioritize throughput over latency.
#
# As a rule of thumb, increasing the number of threads will increase how much
# traffic a given process can handle (throughput), but due to CRuby's
# Global VM Lock (GVL) it has diminishing returns and will degrade the
# response time (latency) of the application.
#
# The default is set to 3 threads as it's deemed a decent compromise between
# throughput and latency for the average Rails application.
#
# Any libraries that use a connection pool or another resource pool should
# be configured to provide at least as many connections as the number of
# threads. This includes Active Record's `pool` parameter in `database.yml`.
require_relative "runtime_configuration"
# WEB_CONCURRENCY (default 1) sets the number of Puma processes. One process is
# Puma's single mode, which the 512 MB plan uses. Two or more run cluster mode:
# each process has its own GVL, so on a 2-CPU plan requests run in parallel,
# and the service gets WEB_CONCURRENCY x RAILS_MAX_THREADS request threads.
# Extra processes do not isolate lock waiters: the shared socket hands
# checkouts to every worker, so a rush can still fill every thread.
# docs/SINGLE_SERVICE_RUNTIME.md lists the settings per plan.
if RuntimeConfiguration.clustered?
  workers RuntimeConfiguration.web_processes
  # Load the app once in the master; workers fork copy-on-write.
  preload_app!
  # The master serves no requests. Close the connections it opened while
  # preloading so no worker inherits a live socket; each worker's pools were
  # already discarded at fork (Active Record's fork tracker) and reconnect on
  # first use.
  before_fork do
    ActiveRecord::Base.connection_handler.clear_all_connections!(:all) if defined?(ActiveRecord::Base)
  end
else
  workers 0
end
# Rejected-webhook counts are buffered in memory (Operations::WebhookRejections);
# write what is pending when the process stops so a deploy doesn't lose a burst.
flush_rejected_webhooks = lambda do
  Operations::WebhookRejections.flush! if defined?(Operations::WebhookRejections)
rescue StandardError
  nil
end
if RuntimeConfiguration.clustered?
  before_worker_shutdown { flush_rejected_webhooks.call }
elsif ENV["RAILS_ENV"] != "test"
  at_exit { flush_rejected_webhooks.call }
end
threads_count = RuntimeConfiguration.web_threads
threads threads_count, threads_count

# Specifies the `port` that Puma will listen on to receive requests; default is 3000.
port ENV.fetch("PORT", 3000)

# Allow puma to be restarted by `bin/rails restart` command.
plugin :tmp_restart

if RuntimeConfiguration.embedded?
  # Released Solid Queue 1.7.0 supervises its actors inside this Puma instance.
  # Async supervisor mode does not change queue persistence to an async adapter.
  # Exactly one supervisor per Puma instance in either mode.
  #
  # Readiness matches queue heartbeats to RuntimeConfiguration.instance_id.
  # Fix it before any fork, so every worker inherits the id the supervisor
  # records.
  RuntimeConfiguration.instance_id

  if RuntimeConfiguration.clustered?
    # Cluster mode: the supervisor runs in request worker 0, never in the
    # master. Puma forks a replacement worker from the master whenever one
    # dies, and fork copies only the calling thread: a master running Solid
    # Queue threads could hand the new worker a mutex (connection pool,
    # logger, libpq) held forever by a thread that no longer exists. The
    # master stays free of job threads, so every respawn forks cleanly. If
    # worker 0 dies, its replacement starts a new supervisor; the old one's
    # rows stop counting for readiness after 90 seconds and are pruned with
    # their claimed jobs, as after any crash.
    embedded_supervisor = nil
    before_worker_boot do |index|
      next unless index.zero?

      embedded_supervisor = SolidQueue::Supervisor.start(mode: :async, standalone: false)
    end
    before_worker_shutdown do |index|
      next unless index.zero?

      embedded_supervisor&.stop
      embedded_supervisor = nil
    end
  else
    # Single mode: the plugin's after_booted hook starts the async supervisor
    # in the only process. Nothing forks after boot.
    plugin :solid_queue
    solid_queue_mode :async
  end
end

# Specify the PID file. Defaults to tmp/pids/server.pid in development.
# In other environments, only set the PID file if requested.
pidfile ENV["PIDFILE"] if ENV["PIDFILE"]
