# frozen_string_literal: true

class EmailRateSlot < ApplicationRecord
  # Reserve future starts atomically, then release the row before waiting or I/O.
  # Only the dedicated bulk worker uses this lane; priority mail bypasses it.
  def self.dispatch!
    sleep(reserve!)
    yield
  end

  def self.reserve!
    slot = create_or_find_by!(name: "resend") { |row| row.available_at = Time.current }
    slot.with_lock do
      now = Time.current
      start = [slot.available_at, now].max
      rate = Float(ENV.fetch("EMAIL_REQUESTS_PER_SECOND", "1"), exception: false).to_f.clamp(0.1, 2.0)
      slot.update!(available_at: start + 1.0 / rate)
      start - now
    end
  end

  def self.backoff!
    slot = find_by(name: "resend")
    slot&.with_lock { slot.update!(available_at: [slot.available_at, 30.seconds.from_now].max) }
  end
end
