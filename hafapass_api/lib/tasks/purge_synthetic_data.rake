# frozen_string_literal: true

namespace :hafapass do
  desc "One-time pre-launch reset: delete all business data except site settings, queue/runtime infrastructure, " \
    "and KEEP_USER_EMAILS users. Requires CONFIRM=PURGE_SYNTHETIC_DATA; refuses if live money moved."
  task purge_synthetic_data: :environment do
    Operations::SyntheticDataPurge.call(confirm: ENV.fetch("CONFIRM", nil), keep_user_emails: ENV.fetch("KEEP_USER_EMAILS", nil))
  rescue Operations::SyntheticDataPurge::Refused => e
    abort "Refused: #{e.message} Nothing was changed."
  end
end
