# frozen_string_literal: true

# Admin → Payouts → Due: every event whose bank transfer or reserve release
# needs finance, with its due date in the event's calendar and the next step.
# Read-only; each row is a PayoutSchedule over the shared settlement
# calculator.
#
# Candidates: events that started and ended in the last LOOKBACK_DAYS; any
# started event, however old, with paid sales; events cancelled before they
# started that still have paid sales (refunds may be outstanding); and any
# event holding a reserve or with a payout in flight. Drafts and archived
# events are excluded (archiving requires the money to be closed), so nothing
# payable ages out. Free-only events never run the calculator unless recent.
# Each candidate runs the calculator once; fully settled events are then
# dropped as "done". Snapshot per event if volumes outgrow that.
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

  # One payout-account lookup per organization, not per event row.
  def payout_account_ready?(organization)
    (@payout_account_ready ||= {}).fetch(organization.id) do
      @payout_account_ready[organization.id] = organization.payout_account.present?
    end
  end

  def organization_available(organization)
    (@organization_available ||= {})[organization.id] ||= OrganizationPayoutBalance.available_cents(organization)
  end

  # Recent ended events, plus every older event that still has money activity
  # and has not been archived (archiving requires its money to be closed), so
  # an unpaid event never ages out of the list. Fully settled older events are
  # computed and then dropped as "done".
  def candidate_events
    started = Event.where(status: %i[published completed cancelled]).where("events.starts_at <= ?", at)
    recent = started.where("COALESCE(events.ends_at, events.starts_at) >= ?", at - LOOKBACK_DAYS.days)
    paid_sales = Order.excluding_test_payments.where(status: OrganizationFinanceSummary::SETTLED_ORDER_STATUSES)
      .where("orders.subtotal_cents > 0").select(:event_id)
    with_sales = started.where(id: paid_sales)
    cancelled_early = Event.where(status: :cancelled).where(id: paid_sales)
    reserved = BalanceAdjustment.effective.where(kind: PayoutSchedule::RESERVE_KINDS).where.not(event_id: nil).select(:event_id)
    in_flight = Payout.where(status: PayoutSchedule::IN_FLIGHT_STATUSES).select(:event_id)
    Event.where(id: recent.select(:id)).or(Event.where(id: with_sales.select(:id)))
      .or(Event.where(id: cancelled_early.select(:id)))
      .or(Event.where(id: reserved)).or(Event.where(id: in_flight))
      .where.not(status: %i[draft archived]).includes(:organization).order(:id)
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
      after_release_cents: schedule.still_to_come_cents,
      reserve_release_due: schedule.reserve_release_due?,
      reserve_released_on: schedule.reserve_released_on,
      reserve_skipped: schedule.reserve_skipped?,
      payout_account_ready: payout_account_ready?(event.organization),
      settlement: settlement && { id: settlement.id, version: settlement.version,
                                  available_to_payout_cents: settlement.available_to_payout_cents,
                                  # What PayoutCreator would accept now: also capped
                                  # by the organization-wide payout balance.
                                  requestable_cents: [settlement.available_to_payout_cents,
                                    organization_available(event.organization)].min },
      in_flight_payout: payout && { id: payout.id, status: payout.status, amount_cents: payout.amount_cents,
                                    disbursement_cents: payout.disbursement_cents },
      currency: event.organization.currency
    }
  end
end
