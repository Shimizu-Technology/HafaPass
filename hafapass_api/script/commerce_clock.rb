# frozen_string_literal: true

# This file is a long-running process entrypoint, not an autoloadable library.
# Keep it outside lib/ so Rails eager loading cannot execute the scheduler while
# booting production or CI.
running = true
Signal.trap("TERM") { running = false }
Signal.trap("INT") { running = false }

clock = Operations::CommerceClock.new
lease = Operations::CommerceClockLease.new
unless lease.acquire!
  Rails.logger.error({ event: "commerce_clock_lease_unavailable" }.to_json)
  exit(1)
end
Rails.logger.info({ event: "commerce_clock_started", interval_seconds: 60 }.to_json)

begin
  while running
    unless lease.renew!
      Rails.logger.error({ event: "commerce_clock_lease_lost" }.to_json)
      break
    end
    clock.tick(at: Time.current)
    60.times do
      break unless running

      sleep 1
    end
  end
ensure
  lease.release!
end
Rails.logger.info({ event: "commerce_clock_stopped" }.to_json)
