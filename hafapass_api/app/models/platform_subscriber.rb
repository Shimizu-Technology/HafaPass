# frozen_string_literal: true

class PlatformSubscriber < ApplicationRecord
  STATUSES = %w[pending confirmed unsubscribed bounced complained].freeze
  SOURCES = %w[footer home checkout event_page waitlist preferences].freeze
  normalizes :email, with: ->(value) { value.strip.downcase }
  has_many :message_deliveries, dependent: :restrict_with_error
  validates :email, format: { with: URI::MailTo::EMAIL_REGEXP }, uniqueness: true, length: { maximum: 254 }
  validates :source, inclusion: { in: SOURCES }
  validates :status, inclusion: { in: STATUSES }
  validates :name, length: { maximum: 120 }
  validate :bounded_preferences
  before_validation(on: :create) { self.confirmation_nonce ||= SecureRandom.hex(24) }

  def self.confirmation_required?
    ENV.fetch("EMAIL_DOUBLE_OPT_IN", "true") != "false"
  end

  def self.confirm!(token)
    # signed_id purpose includes a rotating nonce, so old requests cannot undo an opt-out.
    identity = Rails.application.message_verifier(:email_confirmation).verified(token, purpose: :confirm)
    return unless identity.is_a?(Array)

    subscriber = find_by(id: identity[0])
    subscriber&.with_lock do
      return unless subscriber.confirmation_nonce == identity[1] && subscriber.status == "pending"

      subscriber.update!(status: "confirmed", confirmed_at: Time.current)
      EmailConsent.record!(email: subscriber.email, scope: "platform", action: "confirmed", source: subscriber.source)
    end
    subscriber
  end

  def confirmation_token
    Rails.application.message_verifier(:email_confirmation).generate([id, confirmation_nonce], purpose: :confirm, expires_in: 2.days)
  end

  def mailable?
    status == "confirmed" && !EmailPreference.blocked?(email) && !PrivacyEmailSuppression.for?(email) &&
      !MessageDelivery.new(channel: "email", template: "audience_mailing", recipient: email).suppressed_recipient?
  end

  private

  def bounded_preferences
    [interests, villages].each do |values|
      errors.add(:base, "Invalid preferences") unless values.is_a?(Array) && values.size <= 30 && values.all? { |v| v.is_a?(String) && v.length <= 80 }
    end
  end
end
