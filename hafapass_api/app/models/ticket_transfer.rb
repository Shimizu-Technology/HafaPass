# frozen_string_literal: true

class TicketTransfer < ApplicationRecord
  belongs_to :ticket
  belongs_to :initiated_by_user, class_name: "User", optional: true
  belongs_to :accepted_by_user, class_name: "User", optional: true

  enum :status, { pending: 0, accepted: 1, declined: 2, cancelled: 3, expired: 4 }

  validates :recipient_email, presence: true, format: { with: URI::MailTo::EMAIL_REGEXP }
  validates :expires_at, presence: true
  validates :token_version, numericality: { only_integer: true, greater_than_or_equal_to: 0 }
  validate :one_pending_transfer, on: :create

  before_validation :normalize_recipient

  def active?(at: Time.current)
    pending? && expires_at > at
  end

  private

  def normalize_recipient
    self.recipient_email = recipient_email.to_s.strip.downcase
    self.recipient_name = recipient_name.to_s.strip.presence
  end

  def one_pending_transfer
    return unless ticket&.ticket_transfers&.pending&.exists?

    errors.add(:ticket, "already has a pending transfer")
  end
end
