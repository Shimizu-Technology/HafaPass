# frozen_string_literal: true

# One stable Sentry tag, `area`, for the paths whose errors must reach Leon's
# phone. Sentry alert rules filter on this tag (docs/MONITORING_SETUP.md), so a
# controller rename can't silently drop a path out of an alert.
module MonitoringArea
  AREAS = %w[checkout webhook scanner box_office].freeze

  module_function

  def for_controller(controller_path)
    case controller_path.to_s
    when "api/v1/orders", "api/v1/order_recovery" then "checkout"
    when "webhooks" then "webhook"
    when "api/v1/organizer/scanner_devices", "api/v1/organizer/admissions" then "scanner"
    when "api/v1/organizer/box_office" then "box_office"
    end
  end
end
