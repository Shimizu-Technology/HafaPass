# frozen_string_literal: true

class EventChange < ApplicationRecord
  include AppendOnlyRecord

  belongs_to :event
  belongs_to :actor_user, class_name: "User", optional: true
  has_many :event_change_responses, dependent: :restrict_with_error

  # venue_changed notifies buyers without a self-serve refund; the policy
  # asks them to contact HåfaPass about other material changes.
  TYPES = %w[postponed rescheduled cancelled venue_changed].freeze

  # Organizers often fix a change with a second edit. Non-cancellation notices
  # wait this long, and a notice is replaced when a newer change for the same
  # event follows within the window; the newest notice then describes the
  # whole burst. The rule depends only on change times, never on when a job
  # happened to run.
  NOTICE_COALESCE_WINDOW = 10.minutes

  scope :buyer_visible, -> { where(change_type: TYPES) }

  validates :change_type, inclusion: { in: TYPES }
  validates :occurred_at, presence: true

  attr_readonly :event_id, :actor_user_id, :change_type, :reason, :before_data, :after_data, :occurred_at

  def superseded_notice?
    return false if change_type == "cancelled"

    later_changes.where(occurred_at: ...(occurred_at + NOTICE_COALESCE_WINDOW)).exists?
  end

  # This change and the earlier changes whose notices it replaced, oldest
  # first. A cancellation is never folded into a schedule or venue notice.
  def notice_burst
    burst = [self]
    return burst if change_type == "cancelled"

    earlier_changes.where.not(change_type: "cancelled").order(occurred_at: :desc, id: :desc).each do |previous|
      break unless burst.last.occurred_at - previous.occurred_at < NOTICE_COALESCE_WINDOW

      burst << previous
    end
    burst.reverse
  end

  private

  def later_changes
    event.event_changes.buyer_visible.where.not(id: id)
      .where("occurred_at > :at OR (occurred_at = :at AND id > :id)", at: occurred_at, id: id)
  end

  def earlier_changes
    event.event_changes.buyer_visible.where.not(id: id)
      .where("occurred_at < :at OR (occurred_at = :at AND id < :id)", at: occurred_at, id: id)
  end
end
