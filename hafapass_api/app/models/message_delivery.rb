# frozen_string_literal: true

class MessageDelivery < ApplicationRecord
  belongs_to :order, optional: true
  belongs_to :ticket, optional: true
  belongs_to :event, optional: true
  belongs_to :requested_by, class_name: "User", optional: true
  has_many :message_provider_events, dependent: :nullify

  enum :status, {
    queued: 0, sent: 1, failed: 2, suppressed: 3, delivered: 4, delayed: 5, bounced: 6, complained: 7
  }

  validates :channel, :template, :recipient, :provider, :idempotency_key, presence: true
  validates :idempotency_key, uniqueness: true, length: { maximum: 256 }
  validates :attempts, numericality: { only_integer: true, greater_than_or_equal_to: 0 }
  validate :subject_present

  before_validation :assign_idempotency_key, on: :create

  def retryable?
    failed? && provider_id.blank?
  end

  def suppressed_recipient?
    self.class.where(recipient: recipient.to_s.downcase, status: [:bounced, :complained, :suppressed]).
      where.not(id: id).exists?
  end

  private

  def subject_present
    errors.add(:base, "Order, ticket, or event is required") if order_id.blank? && ticket_id.blank? && event_id.blank?
  end

  def assign_idempotency_key
    self.idempotency_key ||= "message/#{SecureRandom.uuid}"
  end
end
