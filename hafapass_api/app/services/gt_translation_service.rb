# frozen_string_literal: true

require "net/http"

# Machine translation through General Translation's runtime API, the same
# service the frontend's build-time `gt` CLI uses for interface text. Without
# GT_API_KEY and GT_PROJECT_ID nothing is sent and content stays English.
class GtTranslationService
  ENDPOINT = URI("https://runtime2.gtx.dev/v2/translate").freeze
  API_VERSION = "2026-03-06.v1"
  TIMEOUT_SECONDS = 15

  class TranslationError < StandardError; end

  def self.configured?
    ENV["GT_API_KEY"].present? && ENV["GT_PROJECT_ID"].present?
  end

  # Translates { key => English text } into each target locale and returns
  # { key => { locale => text } }. Keys the service did not translate are
  # left out so callers can fall back to English for them.
  def translate(fields, context: nil, locales: AppLocale::TRANSLATION_TARGETS)
    raise TranslationError, "General Translation is not configured" unless self.class.configured?

    requests = fields.each_with_object({}) do |(key, text), entries|
      next if text.blank?

      entries[key.to_s] = { "source" => text.to_s }
      entries[key.to_s]["metadata"] = { "context" => context } if context.present?
    end
    return {} if requests.empty?

    locales.each_with_object({}) do |locale, results|
      response = post(requests, AppLocale.gt_code(locale))
      requests.each_key do |key|
        translation = response.dig(key, "translation")
        (results[key] ||= {})[locale] = translation if translation.is_a?(String) && translation.present?
      end
    end
  end

  private

  def post(requests, target_locale)
    request = Net::HTTP::Post.new(ENDPOINT)
    request["Content-Type"] = "application/json"
    request["x-gt-api-key"] = ENV.fetch("GT_API_KEY")
    request["x-gt-project-id"] = ENV.fetch("GT_PROJECT_ID")
    request["gt-api-version"] = API_VERSION
    request.body = { requests: requests, targetLocale: target_locale, sourceLocale: AppLocale::DEFAULT, metadata: {} }.to_json

    response = Net::HTTP.start(ENDPOINT.host, ENDPOINT.port, use_ssl: true,
      open_timeout: TIMEOUT_SECONDS, read_timeout: TIMEOUT_SECONDS) { |http| http.request(request) }
    raise TranslationError, "General Translation returned HTTP #{response.code}" unless response.is_a?(Net::HTTPSuccess)

    parsed = JSON.parse(response.body)
    raise TranslationError, "General Translation returned an unexpected response" unless parsed.is_a?(Hash)

    parsed
  rescue JSON::ParserError
    raise TranslationError, "General Translation returned invalid JSON"
  rescue Net::OpenTimeout, Net::ReadTimeout, SocketError, SystemCallError, OpenSSL::SSL::SSLError, IOError => e
    raise TranslationError, "General Translation request failed (#{e.class})"
  end
end
