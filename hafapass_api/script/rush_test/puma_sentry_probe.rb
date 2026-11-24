# frozen_string_literal: true

# One-off Puma config that proves Sentry reports from EVERY Puma worker after fork.
# It loads the app's real config/puma.rb unchanged, then adds one hook: when each
# worker boots, it sends one clearly labelled info message through the app's real Sentry
# configuration and logs whether it was accepted for sending.
#
#   cd hafapass_api            # on Render: the shell already starts in /app
#   bundle exec puma -C script/rush_test/puma_sentry_probe.rb      # local
#   # Render (isolated copy only): temporarily set the service Docker command to
#   #   bundle exec puma -C script/rush_test/puma_sentry_probe.rb
#   # redeploy, read the logs, then put the original command back.
#
# Log lines, two per worker (at boot, and again RUSH_SENTRY_PROBE_LATE_SECONDS=20 later):
#   rush_sentry_probe phase=boot worker=0 pid=123 sentry_initialized=true sending_allowed=true environment=rush-copy event_id=ab12...
# A missing event_id (or sending_allowed=false) means that worker would NOT report errors.
# Each message is tagged probe=rush-sentry-fork, worker_index and pid; filter Sentry on the tag.
# It sends nothing but those labelled messages and changes no data.
# Evaluate the real file inside this DSL (Puma's own `load` defers it, which would skip it).
real_config = File.expand_path("config/puma.rb", Dir.pwd)
instance_eval(File.read(real_config), real_config)

before_worker_boot do |index|
  probe = lambda do |phase|
    config = Sentry.configuration
    event = Sentry.with_scope do |scope|
      scope.set_tags(probe: "rush-sentry-fork", worker_index: index.to_s, pid: Process.pid.to_s, phase: phase)
      Sentry.capture_message("rush sentry probe (#{phase}): puma worker #{index} (pid #{Process.pid})", level: :info)
    end
    puts "rush_sentry_probe phase=#{phase} worker=#{index} pid=#{Process.pid} sentry_initialized=#{Sentry.initialized?} " \
         "sending_allowed=#{config&.sending_allowed?} environment=#{config&.environment} " \
         "event_id=#{event&.event_id || 'NONE'}"
    $stdout.flush
  end

  probe.call("boot")
  # A second message later proves the worker's sender still works once idle, not only at boot.
  Thread.new do
    sleep Integer(ENV.fetch("RUSH_SENTRY_PROBE_LATE_SECONDS", "20"))
    probe.call("late")
  end
end
