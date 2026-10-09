# frozen_string_literal: true

require Rails.root.join("lib/telemetry_privacy")
require "action_dispatch/http/request"

ActionDispatch::Request.prepend(TelemetryPrivacy::FilteredRequest)

Rails.application.config.after_initialize do
  TelemetryPrivacy.install_logger!(Rails.logger)
end
