# frozen_string_literal: true

# Decides whether a buyer may refund an order themselves after an event change.
#
# Self-serve refunds follow the published buyer policy: a postponement, or a
# reschedule that actually moved the start time, made after the order was
# placed. A reschedule is judged by its net effect on the order: the start
# time in effect when the order was placed against the start time now, so a
# moved-and-restored start offers nothing (a postponement always does). The
# window closes when a published event starts; a postponed event has no
# deadline until it is resumed. Cancelled events are refunded automatically,
# and completed, archived or draft events are closed. Other changes (end time,
# doors, venue) notify buyers without a self-serve refund.
#
# A buyer responding to a later, non-qualifying change (for example a doors
# correction after a new date) keeps the right earned by the earlier
# qualifying change that their order predates. Keeping the tickets after a
# later change gives up refunds based on earlier ones.
class EventChangeRefundEligibility
  REFUND_CHANGE_TYPES = %w[postponed rescheduled].freeze

  MESSAGES = {
    "no_change" => "This event has no change that offers a refund",
    "change_not_refundable" => "Self-serve refunds are offered when an event is postponed or its start time changes. " \
      "Contact the organizer or HåfaPass support about other changes.",
    "ordered_after_change" => "This order was placed after the event changed, so it is not eligible for a change refund",
    "accepted_later_change" => "You kept your tickets after a later change to this event, so this earlier change no longer offers a refund",
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

  # A recorded refund request keeps the window it was made in only for the
  # tickets it named (a provider refund can fail and be retried with a new
  # key). Any other ticket is judged now, so a replay cannot reopen a closed
  # window for tickets the buyer never asked about.
  def self.for_recorded_request(order:, change:, response:)
    current = call(order: order, change: change)
    return current unless response&.decision == "refund_requested"

    frozen = call(order: order, change: change, at: response.responded_at)
    requested_ids = Array(response.requested_ticket_ids).map(&:to_i)
    requested = frozen.tickets.select { |ticket| requested_ids.include?(ticket.id) }
    tickets = (frozen.eligible? ? requested : []) | (current.eligible? ? current.tickets : [])
    if tickets.any?
      Result.new(eligible: true, reason: nil, deadline_at: current.deadline_at || frozen.deadline_at,
        tickets: tickets.sort_by(&:id), order_predates_change: frozen.order_predates_change)
    else
      # Report the originally requested tickets so a same-key replay presents
      # the same selection to RefundCreator's idempotency check.
      Result.new(eligible: false, reason: current.reason || frozen.reason || "no_tickets", deadline_at: current.deadline_at,
        tickets: requested, order_predates_change: frozen.order_predates_change)
    end
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

  # recorded_request: an administrator executing a buyer request recorded in
  # time. The event may have closed since; only the order, the net change,
  # the tickets and the deadline as of the request decide.
  def initialize(order:, change:, at: Time.current, recorded_request: false, ticket_ids: nil)
    @order = order
    @change = change
    @at = at || Time.current
    @recorded_request = recorded_request
    @ticket_ids = ticket_ids&.map(&:to_i)
  end

  def call
    return result(false, "no_change") unless change

    predates = order.created_at < change.occurred_at
    deadline = deadline_at
    reason = if !recorded_request && (event.cancelled? || change.change_type == "cancelled")
      "event_cancelled"
    elsif !recorded_request && (event.draft? || event.completed? || event.archived?)
      "event_closed"
    elsif deadline && at >= deadline
      "deadline_passed"
    elsif !qualifying?
      predates ? "change_not_refundable" : "ordered_after_change"
    elsif !recorded_request && accepted_later_change?
      "accepted_later_change"
    elsif tickets.empty?
      "no_tickets"
    end

    result(reason.nil?, reason, deadline: deadline, predates: predates)
  end

  private

  attr_reader :order, :change, :at, :recorded_request, :ticket_ids

  def event
    order.event
  end

  # An event closes at its start time as of the evaluation time. A postponed
  # event has no date to hold buyers to until the organizer resumes it.
  def deadline_at
    status, starts_at = state_at(at)
    status == "postponed" ? nil : starts_at
  end

  def buyer_visible_changes
    @buyer_visible_changes ||= if event.event_changes.loaded?
      event.event_changes.select { |candidate| EventChange::TYPES.include?(candidate.change_type) }
    else
      event.event_changes.buyer_visible.to_a
    end.sort_by { |candidate| [candidate.occurred_at, candidate.id] }
  end

  # The event's status and start as they stood at a moment: the before
  # snapshot of the first change after it, or the event as it is now.
  def state_at(time)
    snapshot = buyer_visible_changes.find { |candidate| candidate.occurred_at > time }&.before_data.to_h.stringify_keys
    return [event.status.to_s, event.starts_at] unless snapshot.key?("starts_at")

    [snapshot.fetch("status", event.status).to_s, self.class.parse_time(snapshot["starts_at"])]
  end

  # A postponement made after the order always qualifies. A reschedule
  # qualifies only while the start time differs from the one the order was
  # placed for.
  def qualifying?
    return @qualifying if defined?(@qualifying)

    window = buyer_visible_changes.select do |candidate|
      REFUND_CHANGE_TYPES.include?(candidate.change_type) &&
        candidate.occurred_at > order.created_at && candidate.occurred_at <= change.occurred_at &&
        self.class.refund_qualifying?(candidate)
    end
    @qualifying = window.any? { |candidate| candidate.change_type == "postponed" } ||
      (window.any? && net_start_moved?)
  end

  def net_start_moved?
    # Snapshots keep whole seconds; the event column may not.
    state_at(order.created_at).last&.to_i != state_at(at).last&.to_i
  end

  # Keeping the tickets after a later change waives refunds based on earlier
  # changes. Only choices made by the evaluation time count, so a recorded
  # request is not undone by a later acceptance.
  def accepted_later_change?
    position = buyer_visible_changes.index { |candidate| candidate.id == change.id }
    later_ids = position ? buyer_visible_changes.drop(position + 1).map(&:id) : []
    return false if later_ids.empty?

    order.event_change_responses.where(decision: "accepted", event_change_id: later_ids, responded_at: ..at).exists?
  end

  # Only tickets the order still controls: an accepted transfer belongs to
  # its new holder even though the ticket stays issued.
  def tickets
    @tickets ||= begin
      issued = order.tickets.loaded? ? order.tickets.select(&:issued?) : order.tickets.where(status: :issued).to_a
      issued = issued.select { |ticket| ticket_ids.include?(ticket.id) } if ticket_ids
      issued.sort_by(&:id).reject { |ticket| ticket.transferred_away_from?(order) }
    end
  end

  # Tickets are reported even when ineligible so a replayed request can
  # present the same selection to RefundCreator's idempotency check.
  def result(eligible, reason, deadline: nil, predates: false)
    Result.new(eligible: eligible, reason: reason, deadline_at: deadline,
      tickets: change ? tickets : [], order_predates_change: predates)
  end
end
