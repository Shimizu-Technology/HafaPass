# frozen_string_literal: true

class WaitlistOffer < ApplicationRecord
  belongs_to :waitlist_entry
  belongs_to :event
  belongs_to :ticket_type
  belongs_to :pricing_tier, optional: true
  belongs_to :order, optional: true

  enum :status, { offered: 0, claimed: 1, converted: 2, expired: 3, cancelled: 4 }

  validates :quantity, numericality: { only_integer: true, greater_than: 0 }
  validates :unit_price_cents, numericality: { only_integer: true, greater_than_or_equal_to: 0 }
  validates :expires_at, presence: true
  validates :token_version, numericality: { only_integer: true, greater_than_or_equal_to: 0 }
  validate :consistent_subjects

  scope :holding_inventory, ->(at = Time.current) { offered.where("expires_at > ?", at) }

  def active?(at: Time.current)
    offered? && expires_at > at
  end

  def expire!(at: Time.current, requeue: true)
    with_lock do
      return false unless offered? || claimed?

      update!(status: :expired, token_version: token_version + 1)
      waitlist_entry.update!(status: :waiting, expires_at: nil) if requeue && waitlist_entry.active?
      true
    end
  end

  private

  def consistent_subjects
    return if waitlist_entry.blank? || event.blank? || ticket_type.blank?
    return if waitlist_entry.event_id == event_id && ticket_type.event_id == event_id

    errors.add(:base, "Waitlist offer subjects must belong to the same event")
  end
end
