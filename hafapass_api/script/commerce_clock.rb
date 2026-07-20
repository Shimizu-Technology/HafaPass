# frozen_string_literal: true

# This file is a long-running process entrypoint, not an autoloadable library.
# Keep it outside lib/ so Rails eager loading cannot execute the scheduler while
# booting production or CI.
running = true
Signal.trap("TERM") { running = false }
Signal.trap("INT") { running = false }

Rails.logger.info({ event: "commerce_clock_started", interval_seconds: 60 }.to_json)
while running
  ExpireInventoryHoldsJob.perform_later(Time.current)
  60.times do
    break unless running

    sleep 1
  end
end
Rails.logger.info({ event: "commerce_clock_stopped" }.to_json)
