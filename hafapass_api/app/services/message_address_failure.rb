# frozen_string_literal: true

# One classification for synchronous Resend rejections and webhook failures.
# See docs/LOCKING.md for the terminal-status and address-suppression rules.
class MessageAddressFailure
  PERMANENT_CODES = %w[invalid_email invalid_to_address invalid_recipient recipient_not_found
    mailbox_not_found address_not_found user_unknown].freeze
  SMTP_INVALID_ADDRESS = /\b5\.1\.(?:1|2|3|6|10)\b/
  INVALID_MESSAGE = /(?:recipient|mailbox)\s+(?:not\s+found|does\s+not\s+exist|unknown|invalid)|invalid\s+(?:recipient|mailbox|email address)|email address|does not exist|nonexistent|user unknown/i

  def self.invalid?(message:, code: nil, bounce_type: nil, bounce_subtype: nil, diagnostics: [])
    return false if bounce_type.to_s.casecmp?("Transient")
    return true if PERMANENT_CODES.include?(code.to_s.downcase)
    return true if %w[NoEmail RecipientNotFound].include?(bounce_subtype.to_s)
    return true if Array(diagnostics).any? { |diagnostic| diagnostic.to_s.match?(SMTP_INVALID_ADDRESS) }

    message.to_s.match?(INVALID_MESSAGE)
  end

  def self.synchronous?(error)
    (error.is_a?(Resend::Error::InvalidRequestError) || error.is_a?(Resend::Error::NotFoundError)) &&
      invalid?(message: error.message, code: error.respond_to?(:code) ? error.code : nil)
  end

  def self.receipt?(receipt)
    bounce = receipt.payload.fetch("bounce", {})
    error = receipt.payload.fetch("error", {})
    failed = receipt.payload.fetch("failed", {})
    invalid?(message: error["message"] || bounce["message"] || failed["reason"],
      code: error["code"] || bounce["code"] || failed["reason"],
      bounce_type: bounce["type"], bounce_subtype: bounce["subType"], diagnostics: bounce["diagnosticCode"])
  end
end
