# frozen_string_literal: true

if ENV["RESEND_API_KEY"].present?
  Resend.api_key = ENV["RESEND_API_KEY"]
end

# The Resend SDK sends through HTTParty's module-level client, whose default
# is Net::HTTP's 60 s per phase. Bound each phase so a stalled provider can't
# hold a Puma thread (the guest privacy code is sent inside a request) or the
# single job thread. Nothing else in the app uses HTTParty directly.
HTTParty::Basement.default_timeout(10)
