# frozen_string_literal: true

class CommunicationCampaign < ApplicationRecord
  SEGMENT_TYPES = %w[all_attendees checked_in not_checked_in ticket_type].freeze

  belongs_to :event
  belongs_to :created_by_user, class_name: "User"
  has_many :message_deliveries, dependent: :restrict_with_error

  enum :status, { draft: 0, scheduled: 1, sending: 2, sent: 3, cancelled: 4, failed: 5 }

  validates :name, :subject, :body, presence: true
  validates :subject, length: { maximum: 240 }
  validates :body, length: { maximum: 20_000 }
  validates :recipient_count, numericality: { only_integer: true, greater_than_or_equal_to: 0 }
  validate :valid_segment

  def segment_type
    segment["type"].to_s
  end

  private

  def valid_segment
    errors.add(:segment, "type is invalid") unless SEGMENT_TYPES.include?(segment_type)
    if segment_type == "ticket_type" && segment["ticket_type_id"].blank?
      errors.add(:segment, "ticket type is required")
    end
  end
end
