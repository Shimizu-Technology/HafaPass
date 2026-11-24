# frozen_string_literal: true

class EmailRateSlot < ApplicationRecord
  # Resend defaults to 10 requests/second per team: https://resend.com/docs/api-reference/introduction#rate-limit
  # Reserve one request/second by default, leaving room for other team traffic; cap this app at 2/second.
  def self.reserve!
    slot = create_or_find_by!(name: "resend") { |row| row.available_at = Time.current }
    slot.with_lock do
      now = Time.current
      return slot.available_at - now if slot.available_at > now

      rate = Float(ENV.fetch("EMAIL_REQUESTS_PER_SECOND", "1"), exception: false).to_f.clamp(0.1, 2.0)
      slot.update!(available_at: now + 1.0 / rate)
      0
    end
  end

  def self.backoff!
    slot = find_by(name: "resend")
    slot&.with_lock { slot.update!(available_at: [slot.available_at, 30.seconds.from_now].max) }
  end
end
