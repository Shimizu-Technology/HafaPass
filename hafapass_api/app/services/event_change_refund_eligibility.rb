# frozen_string_literal: true

# Decides whether a buyer may refund an order themselves after an event change.
#
# Self-serve refunds follow the published buyer policy: a postponement, or a
# reschedule that actually moved the start time, made after the order was
# placed. The window closes when a published event starts; a postponed event
# has no deadline until it is resumed. Cancelled events are refunded
# automatically, and completed, archived or draft events are closed. Other
# changes (end time, doors, venue) notify buyers without a self-serve refund.
#
# A buyer responding to a later, non-qualifying change (for example a doors
# correction after a new date) keeps the right earned by the earlier
# qualifying change that their order predates.
class EventChangeRefundEligibility
  REFUND_CHANGE_TYPES = %w[postponed rescheduled].freeze

  MESSAGES = {
    "no_change" => "This event has no change that offers a refund",
    "change_not_refundable" => "Self-serve refunds are offered when an event is postponed or its start time changes. " \
      "Contact the organizer or HåfaPass support about other changes.",
    "ordered_after_change" => "This order was placed after the event changed, so it is not eligible for a change refund",
    "event_cancelled" => "Cancelled events are refunded automatically",
    "event_closed" => "Change refunds are closed for this event",
    "deadline_passed" => "Change refunds closed when the event started",
    "no_tickets" => "No active tickets on this order can be refunded"
  }.freeze

  Result = Data.define(:eligible, :reason, :deadline_at, :tickets, :order_predates_change) do
    def eligible? = eligible

    def message
      MESSAGES.fetch(reason, "This order is not eligible for a change refund") unless eligible
    end
  end

  def self.call(...)
    new(...).call
  end

  def self.refund_qualifying?(change)
    return false unless change
    return true if change.change_type == "postponed"
    return false unless change.change_type == "rescheduled"

    before = change.before_data.to_h.stringify_keys
    after = change.after_data.to_h.stringify_keys
    return false unless before.key?("starts_at") && after.key?("starts_at")

    parse_time(before["starts_at"]) != parse_time(after["starts_at"])
  end

  def self.parse_time(value)
    value.present? ? Time.zone.parse(value.to_s) : nil
  rescue ArgumentError
    value
  end
  private_class_method :parse_time

  def initialize(order:, change:, at: Time.current)
    @order = order
    @change = change
    @at = at || Time.current
  end

  def call
    return result(false, "no_change") unless change

    predates = order.created_at < change.occurred_at
    deadline = deadline_at
    reason = if event.cancelled? || change.change_type == "cancelled"
      "event_cancelled"
    elsif event.draft? || event.completed? || event.archived?
      "event_closed"
    elsif deadline && at >= deadline
      "deadline_passed"
    elsif qualifying_change.nil?
      predates ? "change_not_refundable" : "ordered_after_change"
    elsif tickets.empty?
      "no_tickets"
    end

    result(reason.nil?, reason, deadline: deadline, predates: predates)
  end

  private

  attr_reader :order, :change, :at

  def event
    order.event
  end

  # Published events close at their start time. A postponed event has no
  # date to hold buyers to until the organizer resumes it.
  def deadline_at
    event.published? ? event.starts_at : nil
  end

  def qualifying_change
    return @qualifying_change if defined?(@qualifying_change)

    candidates = if event.event_changes.loaded?
      event.event_changes.select { |candidate| REFUND_CHANGE_TYPES.include?(candidate.change_type) }
    else
      event.event_changes.where(change_type: REFUND_CHANGE_TYPES).to_a
    end
    @qualifying_change = candidates
      .select { |candidate| candidate.occurred_at > order.created_at && candidate.occurred_at <= change.occurred_at }
      .select { |candidate| self.class.refund_qualifying?(candidate) }
      .max_by { |candidate| [candidate.occurred_at, candidate.id] }
  end

  # Only tickets the order still controls: an accepted transfer belongs to
  # its new holder even though the ticket stays issued.
  def tickets
    @tickets ||= order.tickets.where(status: :issued).order(:id).to_a
      .reject { |ticket| ticket.transferred_away_from?(order) }
  end

  # Tickets are reported even when ineligible so a replayed request can
  # present the same selection to RefundCreator's idempotency check.
  def result(eligible, reason, deadline: nil, predates: false)
    Result.new(eligible: eligible, reason: reason, deadline_at: deadline,
      tickets: change ? tickets : [], order_predates_change: predates)
  end
end
