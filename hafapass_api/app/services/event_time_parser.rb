# frozen_string_literal: true

class EventTimeParser
  LOCAL_DATETIME = /\A\d{4}-\d{2}-\d{2}T\d{2}:\d{2}(?::\d{2}(?:\.\d+)?)?\z/
  ISO_OFFSET = /(?:Z|[+-]\d{2}:?\d{2})\z/i

  class ParseError < StandardError; end

  def self.call(value, timezone: "Pacific/Guam")
    return if value.blank?
    return value.in_time_zone(timezone).utc if value.respond_to?(:in_time_zone) && !value.is_a?(String)

    input = value.to_s
    if input.match?(LOCAL_DATETIME)
      zone = ActiveSupport::TimeZone[timezone]
      raise ParseError, "Timezone must be a valid IANA timezone" unless zone

      local_time = zone.iso8601(input)
      wall_time = input.length == 16 ? local_time.strftime("%FT%R") : local_time.strftime("%FT%T")
      unless wall_time == input.split(".", 2).first
        raise ParseError, "Choose a valid date and time in #{timezone}"
      end

      local_time.utc
    elsif input.match?(ISO_OFFSET)
      Time.iso8601(input).utc
    else
      raise ParseError, "Invalid date and time"
    end
  rescue ArgumentError
    raise ParseError, "Invalid date and time"
  end
end
