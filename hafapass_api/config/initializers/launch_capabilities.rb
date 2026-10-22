# frozen_string_literal: true

# A misspelled launch scope or capability must stop a deployed boot instead of
# silently shipping a different feature set.
Rails.application.config.after_initialize do
  LaunchCapabilities.validate! if Rails.env.production? || Rails.env.staging?
end
