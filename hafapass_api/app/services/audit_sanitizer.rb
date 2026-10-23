# frozen_string_literal: true

require "uri"

class AuditSanitizer
  REDACTED = "[redacted]"
  SENSITIVE_KEY = /(?:password|secret|token|credential|authorization|card_number|card_data|\Apan\z|\Acvc\z|\Acvv\z|raw_payload|outbound_payload|outbound_wire_body|scan_code)/i
  FREE_TEXT_KEY = /(?:note|reason|message|body|description|text|error)/i
  SEARCH_KEY = /\A(?:search|search_term|query|q)\z/i
  TIN_KEY = /\A(?:tin|ssn|taxpayer_id|tax_id|tax_information_tin)\z/i
  MAX_TEXT_LENGTH = 500

  def self.call(value, key: nil, depth: 0)
    return REDACTED if depth > 12
    return REDACTED if key.to_s.match?(SENSITIVE_KEY) || key.to_s.match?(TIN_KEY)
    return value.present? if key.to_s.match?(SEARCH_KEY)

    case value
    when Hash
      value.each_with_object({}) do |(name, item), result|
        # Store whether an export was searched, never its search term.
        output_key = name.to_s.match?(SEARCH_KEY) ? "search_used" : name.to_s
        result[output_key] = call(item, key: name, depth: depth + 1)
      end
    when Array
      value.first(200).map { |item| call(item, key: key, depth: depth + 1) }
    when String
      sanitize_text(value, key: key)
    when Integer
      # Typed monetary values and record identities are numbers, not pasted
      # account/card data. Sensitive keys were rejected before this branch.
      typed_number = key.to_s.match?(/(?:_cents|_bps|_id|_count)\z|\A(?:id|quantity|position|version)\z/)
      !typed_number && value.to_s.match?(/\A(?:\d{9}|\d{13,19})\z/) ? REDACTED : value
    else
      value
    end
  end

  def self.sanitize_text(value, key: nil)
    # A generated UUID is an export identity, not pasted numeric PII. Keep it
    # intact so streamed failures can be matched to their encrypted ticket.
    if key.to_s == "export_request_id" && value.match?(/\A[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}\z/i)
      return value
    end
    text = value.dup
    # Strip URL credentials, query strings and fragments in every snapshot,
    # including verification links nested in a verification diff.
    text = text.gsub(%r{https?://[^\s<>"']+}i) do |url|
      uri = URI.parse(url)
      uri.user = nil
      uri.password = nil
      uri.query = nil
      uri.fragment = nil
      uri.to_s
    rescue URI::InvalidURIError
      REDACTED
    end
    return REDACTED if key.to_s.match?(FREE_TEXT_KEY) && !BackupWithholding.safe_text?(text)

    text = text.gsub(/(?<!\d)(?:\d{3}[-. ]\d{2}[-. ]\d{4}|\d{2}-\d{7}|\d{9})(?!\d)/, REDACTED)
    text = text.gsub(/(?<!\d)(?:\d[ -]?){13,19}(?!\d)/, REDACTED)
    text = text.gsub(/\b(?:sk|pk|rk)_(?:live|test)_[A-Za-z0-9]+|\bBearer\s+\S+|\beyJ[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+(?:\.[A-Za-z0-9_-]+)?/i, REDACTED)
    text = text.gsub(/\b(?:token|secret|password|api[_ -]?key)\s*[:=]\s*\S+/i, REDACTED)
    text.truncate(MAX_TEXT_LENGTH)
  end
  private_class_method :sanitize_text
end
