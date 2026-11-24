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
# Puma's single mode, which the 512 MB plan uses. Larger plans may run two or
# more, so requests waiting on one event's inventory lock cannot take every
# request thread. docs/SINGLE_SERVICE_RUNTIME.md lists the settings per plan.
if RuntimeConfiguration.clustered?
  workers RuntimeConfiguration.web_processes
  # Load the app once in the master: workers fork copy-on-write, and the
  # embedded Solid Queue supervisor below runs in the master.
  preload_app!
else
  workers 0
end
threads_count = RuntimeConfiguration.web_threads
threads threads_count, threads_count

# Specifies the `port` that Puma will listen on to receive requests; default is 3000.
port ENV.fetch("PORT", 3000)

# Allow puma to be restarted by `bin/rails restart` command.
plugin :tmp_restart

if RuntimeConfiguration.embedded?
  # Released Solid Queue 1.7.0 supervises its actors inside this Puma process.
  # Async supervisor mode does not change queue persistence to an async adapter.
  #
  # Exactly one supervisor per Puma instance: plugins start in the Puma master,
  # and the plugin's after_booted hook starts the async supervisor there once,
  # never in the forked request workers. With one process, the master is the
  # only process.
  plugin :solid_queue
  solid_queue_mode :async
  # Readiness matches queue heartbeats to RuntimeConfiguration.instance_id.
  # Fix it in the master before workers fork, so every worker inherits the id
  # the supervisor records.
  RuntimeConfiguration.instance_id
end

# Specify the PID file. Defaults to tmp/pids/server.pid in development.
# In other environments, only set the PID file if requested.
pidfile ENV["PIDFILE"] if ENV["PIDFILE"]
