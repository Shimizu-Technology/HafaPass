# frozen_string_literal: true

# Admin → Payouts → Due: every event whose bank transfer or reserve release
# needs finance, with its due date in the event's calendar and the next step.
# Read-only; each row is a PayoutSchedule over the shared settlement
# calculator.
#
# Candidates: events that ended in the last LOOKBACK_DAYS, plus any older event
# that still holds a reserve or has a payout in flight. Launch-sized volumes
# make one calculator run per candidate acceptable; snapshot if this grows.
class AdminPayoutDueList
  LOOKBACK_DAYS = 120
  TRANSFER_STEPS = %w[complete_event resolve_money hold_reserve finalize_statement send_transfer record_transfer].freeze
  RESERVE_STEPS = %w[release_reserve wait_for_reserve].freeze
  STEP_LABELS = {
    "complete_event" => "Mark the event completed",
    "resolve_money" => "Resolve refunds, disputes or reconciliation",
    "hold_reserve" => "Hold the reserve",
    "finalize_statement" => "Finalize the statement",
    "send_transfer" => "Request the payout and send the bank transfer",
    "record_transfer" => "Record the bank transfer",
    "release_reserve" => "Release the reserve",
    "wait_for_reserve" => "Reserve held",
    "negative_balance" => "Organizer owes a balance"
  }.freeze

  def self.call(at: Time.current, filter: nil)
    new(at: at, filter: filter).call
  end

  def initialize(at:, filter:)
    @at = at
    @filter = filter.to_s
  end

  def call
    rows = candidate_events.filter_map { |event| row(PayoutSchedule.for(event, at: at)) }
    rows = rows.select { |row| %w[due overdue].include?(row[:due_state]) } if filter == "due_now"
    transfers, reserves = rows.partition { |row| TRANSFER_STEPS.include?(row[:next_step]) || row[:next_step] == "negative_balance" }
    order = ->(row) { [row[:due_on] || Date.new(9999), row[:event][:id]] }
    {
      generated_at: at,
      rules: {
        transfer_business_days: "#{PayoutSchedule::TRANSFER_EARLIEST_BUSINESS_DAYS}–#{PayoutSchedule::TRANSFER_DUE_BUSINESS_DAYS}",
        reserve_percent: PayoutSchedule::RESERVE_RATE_BPS / 100,
        reserve_days: PayoutSchedule::RESERVE_DAYS,
        timezone: PayoutCalendar::DEFAULT_TIMEZONE
      },
      counts: {
        overdue: rows.count { |row| row[:due_state] == "overdue" },
        due: rows.count { |row| row[:due_state] == "due" },
        upcoming: rows.count { |row| row[:due_state] == "upcoming" }
      },
      transfers: transfers.sort_by(&order),
      reserves: reserves.sort_by(&order)
    }
  end

  private

  attr_reader :at, :filter

  def candidate_events
    recent = Event.where(status: %i[published completed cancelled])
      .where("COALESCE(events.ends_at, events.starts_at) >= ?", at - LOOKBACK_DAYS.days)
      .where("events.starts_at <= ?", at)
    reserved = BalanceAdjustment.effective.where(kind: PayoutSchedule::RESERVE_KINDS).where.not(event_id: nil).select(:event_id)
    in_flight = Payout.where(status: PayoutSchedule::IN_FLIGHT_STATUSES).select(:event_id)
    Event.where(id: recent.select(:id)).or(Event.where(id: reserved)).or(Event.where(id: in_flight))
      .where.not(status: :draft).includes(:organization).order(:id)
  end

  def row(schedule)
    return unless schedule.ended?
    return unless schedule.money_activity?

    step = schedule.next_step
    return if step == "done"

    event = schedule.event
    settlement = schedule.payable_settlement
    payout = schedule.in_flight_payout
    {
      event: { id: event.id, title: event.title, slug: event.slug, status: event.status,
               ended_at: schedule.ended_at, timezone: PayoutCalendar.timezone_for(event).tzinfo.name },
      organization: { id: event.organization_id, name: event.organization.name },
      next_step: step,
      next_step_label: STEP_LABELS.fetch(step, step.humanize),
      blocker: schedule.money_blocker,
      actions: schedule.available_actions,
      ended_on: schedule.end_date,
      transfer_earliest_on: schedule.transfer_earliest_on,
      transfer_due_on: schedule.transfer_due_on,
      reserve_release_on: schedule.reserve_release_on,
      due_on: schedule.due_on,
      due_state: schedule.due_state,
      overdue_business_days: schedule.overdue_business_days,
      net_proceeds_cents: schedule.net_before_reserve_cents,
      suggested_reserve_cents: schedule.reserve_hold_posted? ? nil : schedule.suggested_reserve_cents,
      reserve_held_cents: schedule.reserve_held_cents,
      reserve_released_cents: schedule.reserve_released_cents,
      paid_cents: schedule.paid_cents,
      in_flight_cents: schedule.in_flight_cents,
      owed_cents: schedule.owed_cents,
      # What is left to send once the reserve is released (negative: owed).
      after_release_cents: schedule.owed_cents + schedule.reserve_held_cents,
      payout_account_ready: event.organization.payout_account.present?,
      settlement: settlement && { id: settlement.id, version: settlement.version,
                                  available_to_payout_cents: settlement.available_to_payout_cents },
      in_flight_payout: payout && { id: payout.id, status: payout.status, amount_cents: payout.amount_cents,
                                    disbursement_cents: payout.disbursement_cents },
      currency: event.organization.currency
    }
  end
end
