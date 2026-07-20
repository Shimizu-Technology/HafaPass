# frozen_string_literal: true

class MessageDelivery < ApplicationRecord
  belongs_to :order, optional: true
  belongs_to :ticket, optional: true
  belongs_to :requested_by, class_name: "User", optional: true

  enum :status, { queued: 0, sent: 1, failed: 2, suppressed: 3 }

  validates :channel, :template, :recipient, presence: true
  validates :attempts, numericality: { only_integer: true, greater_than_or_equal_to: 0 }
  validate :subject_present

  private

  def subject_present
    errors.add(:base, "Order or ticket is required") if order_id.blank? && ticket_id.blank?
  end
end
