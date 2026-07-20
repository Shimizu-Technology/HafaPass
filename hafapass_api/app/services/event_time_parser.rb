# frozen_string_literal: true

class EventTimeParser
  LOCAL_DATETIME = /\A\d{4}-\d{2}-\d{2}T\d{2}:\d{2}(?::\d{2})?\z/

  class ParseError < StandardError; end

  def self.call(value, timezone: "Pacific/Guam")
    return if value.blank?
    return value.in_time_zone if value.respond_to?(:in_time_zone) && !value.is_a?(String)

    input = value.to_s
    if input.match?(LOCAL_DATETIME)
      zone = ActiveSupport::TimeZone[timezone]
      raise ParseError, "Timezone must be a valid IANA timezone" unless zone

      zone.parse(input)&.utc || raise(ParseError, "Invalid local date and time")
    else
      Time.iso8601(input).utc
    end
  rescue ArgumentError
    raise ParseError, "Invalid date and time"
  end
end
