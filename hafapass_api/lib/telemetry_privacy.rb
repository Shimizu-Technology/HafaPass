# frozen_string_literal: true

# URL credentials are bearer capabilities, even when they are not query params.
# Apply the same boundary to Rails logs, structured logs, and Sentry exports.
module TelemetryPrivacy
  FILTERED = "[FILTERED]"
  SECRET_PATH = %r{(/(?:tickets|check_in|ticket-transfers|organization-invitations)/)([^/]+)}i
  URL_IN_TEXT = %r{https?://[^\s<>"']+|/[^\s<>"']+}i
  SECRET_KEY = /authorization|cookie|token|credential|qr_code|password|secret|email|phone|query(?:_string)?|http\.query|request_body|\Abody\z/i
  URL_KEY = /url|href|path|location|referer|referrer|transaction|\A(?:from|to)\z/i

  class << self
    def path(value)
      return value unless value.is_a?(String)

      value.split(/[?#]/, 2).first.to_s.gsub(SECRET_PATH) do
        prefix, segment = Regexp.last_match.captures
        %w[accept].include?(segment) && !prefix.downcase.end_with?("/tickets/", "/check_in/") ? "#{prefix}#{segment}" : "#{prefix}#{FILTERED}"
      end
    end

    def text(value)
      return value unless value.is_a?(String)

      value.gsub(URL_IN_TEXT) { |url| path(url) }
    end

    def scrub(value, key: nil)
      return FILTERED if key && key.to_s.match?(SECRET_KEY)

      case value
      when Hash then value.to_h { |name, item| [name, scrub(item, key: name)] }
      when Array then value.map { |item| scrub(item) }
      when String then key && key.to_s.match?(URL_KEY) ? path(value) : text(value)
      else value
      end
    end

    def breadcrumb(breadcrumb)
      breadcrumb.message = text(breadcrumb.message)
      breadcrumb.data = scrub(breadcrumb.data)
      breadcrumb
    end

    def event(event)
      if request = event.request
        request.url = path(request.url)
        request.query_string = nil
        request.cookies = nil
        request.data = request.data.is_a?(Hash) ? scrub(parameter_filter.filter(request.data)) : nil
        request.headers = scrub(request.headers)
        request.env = scrub(request.env)
      end
      %i[tags extra contexts user dynamic_sampling_context].each do |attribute|
        event.public_send("#{attribute}=", scrub(event.public_send(attribute)))
      end
      event.transaction = path(event.transaction)
      event.message = text(event.message)
      event.breadcrumbs&.each { |item| breadcrumb(item) }
      if event.respond_to?(:exception)
        event.exception&.values&.each { |exception| exception.value = text(exception.value) }
      end
      event.spans = scrub(event.spans) if event.respond_to?(:spans)
      event.profile = scrub(event.profile) if event.respond_to?(:profile)
      event
    end

    def install_logger!(logger)
      if logger.respond_to?(:broadcasts)
        logger.broadcasts.each { |target| install_logger!(target) }
      else
        logger.formatter ||= ActiveSupport::Logger::SimpleFormatter.new
        logger.formatter.singleton_class.prepend(SafeFormatter) unless logger.formatter.is_a?(SafeFormatter)
      end
    end

    private

    def parameter_filter
      ActiveSupport::ParameterFilter.new(Rails.application.config.filter_parameters)
    end
  end

  # This leaves the original formatter and TaggedLogging's tag API intact.
  module SafeFormatter
    def call(severity, time, progname, message)
      TelemetryPrivacy.text(super(severity, time, TelemetryPrivacy.text(progname), TelemetryPrivacy.scrub(message)))
    end
  end

  # filtered_path/filtered_parameters are Rails' observability views. Never
  # modify path, fullpath, params or the Rack environment used for routing.
  module FilteredRequest
    def filtered_path
      TelemetryPrivacy.path(super)
    end

    def filtered_parameters
      super.merge(query_parameters.transform_values { TelemetryPrivacy::FILTERED })
    rescue ActionDispatch::Http::Parameters::ParseError
      {}
    end
  end
end
