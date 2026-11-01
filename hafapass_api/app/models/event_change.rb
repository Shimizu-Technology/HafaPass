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

  NOTICE_TIME_KEYS = %w[starts_at doors_open_at ends_at].freeze
  NOTICE_VENUE_KEYS = %w[venue_name venue_address venue_city].freeze

  # What a buyer-facing snapshot comparison shows: moved times, a different
  # venue (only fields both snapshots recorded; older ones have no village)
  # and a status change.
  def self.changed_snapshot_keys(before, after)
    before = before.to_h.stringify_keys
    after = after.to_h.stringify_keys
    shared = ->(keys) { keys.select { |key| before.key?(key) && after.key?(key) } }
    keys = shared.call(NOTICE_TIME_KEYS).reject { |key| parse_snapshot_time(before[key]) == parse_snapshot_time(after[key]) }
    keys << "venue" if shared.call(NOTICE_VENUE_KEYS).any? { |key| before[key].to_s.strip != after[key].to_s.strip }
    keys << "status" if shared.call(%w[status]).any? { |key| before[key].to_s != after[key].to_s }
    keys
  end

  def self.parse_snapshot_time(value)
    Time.zone.parse(value.to_s) if value.present?
  rescue ArgumentError
    value
  end

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

  # The changes one recipient's notice describes: the burst, less any change
  # made before their order was placed (they bought the event as it was then).
  def notice_burst_for(order)
    burst = notice_burst
    return burst unless order&.created_at

    burst.select { |item| item.occurred_at > order.created_at }.presence || [self]
  end

  # The state the notice compares with the current one.
  def notice_before_data(order = nil)
    notice_burst_for(order).first.before_data.to_h.stringify_keys
  end

  # A burst that nets to nothing for this recipient (a start time moved and
  # put back, say) sends no notice. Cancellations always do.
  def notice_needed?(order = nil)
    return true if change_type == "cancelled"

    self.class.changed_snapshot_keys(notice_before_data(order), after_data).any?
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
