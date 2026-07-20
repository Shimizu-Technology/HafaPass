# frozen_string_literal: true

class EventChangeResponse < ApplicationRecord
  include AppendOnlyRecord

  belongs_to :event_change
  belongs_to :order

  DECISIONS = %w[accepted refund_requested].freeze

  validates :decision, inclusion: { in: DECISIONS }
  validates :responded_at, presence: true
  validates :order_id, uniqueness: { scope: :event_change_id }
  validate :order_belongs_to_changed_event

  private

  def order_belongs_to_changed_event
    return if event_change.blank? || order.blank? || event_change.event_id == order.event_id

    errors.add(:order, "must belong to the changed event")
  end
end
