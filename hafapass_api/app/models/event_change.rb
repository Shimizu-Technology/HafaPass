# frozen_string_literal: true

class EventChange < ApplicationRecord
  include AppendOnlyRecord

  belongs_to :event
  belongs_to :actor_user, class_name: "User", optional: true
  has_many :event_change_responses, dependent: :restrict_with_error

  # venue_changed notifies buyers without a self-serve refund; the policy
  # asks them to contact HåfaPass about other material changes.
  TYPES = %w[postponed rescheduled cancelled venue_changed].freeze

  scope :buyer_visible, -> { where(change_type: TYPES) }

  validates :change_type, inclusion: { in: TYPES }
  validates :occurred_at, presence: true

  attr_readonly :event_id, :actor_user_id, :change_type, :reason, :before_data, :after_data, :occurred_at
end
