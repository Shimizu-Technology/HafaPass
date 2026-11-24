# frozen_string_literal: true

# The standard bank-transfer schedule for one event, read from the same
# settlement calculator the statements and PayoutCreator use:
#
# - send net proceeds less a chargeback reserve within 2–3 business days after
#   the event ends (event-local calendar, Guam by default);
# - hold about 10% of the platform-held net proceeds as that reserve;
# - release the reserve 30 days after the event, then send what remains.
#
# Read-only. It never posts adjustments, finalizes or pays; PayoutReserves,
# Settlements::Finalizer and PayoutCreator do that under their own locks.
class PayoutSchedule
  TRANSFER_EARLIEST_BUSINESS_DAYS = 2
  TRANSFER_DUE_BUSINESS_DAYS = 3
  RESERVE_RATE_BPS = 1000
  RESERVE_DAYS = 30
  RESERVE_KINDS = %w[reserve_hold reserve_release].freeze
  IN_FLIGHT_STATUSES = %w[pending processing held].freeze
  # Any of these means the event's money is already committed to a payout, so
  # a reserve can no longer be carved out of it (Payout::MONEY_RESERVED_STATUSES).
  COMMITTED_STATUSES = Payout::MONEY_RESERVED_STATUSES.map(&:to_s).freeze
  SKIP_ACTION = "payout_reserve.skipped"
  ORGANIZER_DIRECT_CARD_METHODS = %w[door_card].freeze

  def self.for(event, at: Time.current, result: nil)
    new(event, at: at, result: result)
  end

  # Platform-held net proceeds before any reserve: organizer proceeds less
  # organizer-borne processing, lost disputes and door cash the organizer kept,
  # plus manual credits and debits. Unfloored: refunds and chargebacks can make
  # it negative.
  def self.net_before_reserve_cents(attributes)
    attributes[:organizer_proceeds_cents] - attributes[:processing_fee_cents] + attributes[:adjustment_cents]
  end

  # What the organizer is owed before any payout: net proceeds less the reserve
  # currently held. Calculator's payable_cents is this floored at zero.
  def self.balance_before_payout_cents(attributes)
    net_before_reserve_cents(attributes) - attributes[:reserve_cents]
  end

  # Whole cents, half up. Nothing is held against a zero or negative balance.
  def self.suggested_reserve_cents(net_cents, rate_bps: RESERVE_RATE_BPS)
    return 0 unless net_cents.positive?

    ((net_cents * rate_bps) + 5_000) / 10_000
  end

  attr_reader :event, :at

  def initialize(event, at:, result:)
    @event = event
    @at = at
    @result = result
  end

  def result
    @result ||= Settlements::Calculator.call(event)
  end

  def attributes
    result.attributes
  end

  def ended_at
    @ended_at ||= event.effective_ends_at
  end

  def ended?
    return true if event.completed? || event.cancelled? || event.archived?

    ended_at.present? && ended_at <= at
  end

  def end_date
    PayoutCalendar.local_date(ended_at, event)
  end

  def today
    PayoutCalendar.today(event, at: at)
  end

  def transfer_earliest_on
    end_date && PayoutCalendar.add_business_days(end_date, TRANSFER_EARLIEST_BUSINESS_DAYS)
  end

  def transfer_due_on
    end_date && PayoutCalendar.add_business_days(end_date, TRANSFER_DUE_BUSINESS_DAYS)
  end

  # The standard release date for a new hold: 30 days after the event ends.
  def standard_release_on
    end_date && end_date + RESERVE_DAYS
  end

  # The release date agreed when the reserve was held, stored on the hold and
  # immutable; editing the event later cannot move it. Older hand-entered holds
  # without a date fall back to the standard date.
  def reserve_release_on
    stored = active_holds.filter_map(&:reserve_release_on).max
    stored || standard_release_on
  end

  def reserve_release_due?
    reserve_release_on.present? && today >= reserve_release_on
  end

  # The day the reserve was actually released, in the event's calendar.
  def reserve_released_on
    release = reserve_adjustments.select do |adjustment|
      adjustment.kind == "reserve_release" && adjustment.status_posted? && adjustment.reversal_of_id.nil?
    end.max_by(&:effective_at)
    release && PayoutCalendar.local_date(release.effective_at, event)
  end

  # The remainder after a release is due 3 business days after the day it was
  # actually released; the release day itself is not day one.
  def remainder_due_on
    released = reserve_released_on
    released && PayoutCalendar.add_business_days(released, TRANSFER_DUE_BUSINESS_DAYS)
  end

  def net_before_reserve_cents
    self.class.net_before_reserve_cents(attributes)
  end

  def balance_before_payout_cents
    self.class.balance_before_payout_cents(attributes)
  end

  # Card sales taken on the organizer's own terminal (Clover, order payment
  # method door_card): the organizer's processor settles them to the
  # organizer, so HåfaPass never holds that money. Read from the calculator's
  # own sale and refund items. Door cash is already outside net proceeds.
  def organizer_direct_card_cents
    @organizer_direct_card_cents ||= begin
      meta = ->(item) { item[:metadata].to_h.with_indifferent_access }
      sales = result.items.select { |item| item[:kind] == "sale_proceeds" }
      refunds = result.items.select { |item| item[:kind] == "refund" }
      order_ids = sales.filter_map { |item| meta.call(item)[:order_id] }.uniq
      direct = Set.new(Order.where(id: order_ids, payment_method: ORGANIZER_DIRECT_CARD_METHODS).pluck(:id) +
        Payment.where(order_id: order_ids, provider: CardPresentAccount::PROVIDERS).pluck(:order_id))
      if direct.empty?
        0
      else
        refund_orders = Refund.where(id: refunds.filter_map { |item| meta.call(item)[:refund_id] }).pluck(:id, :order_id).to_h
        sold = sales.select { |item| direct.include?(meta.call(item)[:order_id]) }.sum { |item| item[:amount_cents] }
        returned = refunds.select { |item| direct.include?(refund_orders[meta.call(item)[:refund_id]]) }
          .sum { |item| -item[:amount_cents] }
        sold - returned
      end
    end
  end

  # The base for the chargeback reserve: net proceeds HåfaPass actually holds
  # (agent-collected online card sales after organizer-borne processing,
  # disputes and adjustments). Door cash and organizer-direct card sales are
  # excluded; a reserve is never carved out of money the organizer already has.
  def custodial_net_cents
    net_before_reserve_cents - organizer_direct_card_cents
  end

  def suggested_reserve_cents
    self.class.suggested_reserve_cents(custodial_net_cents)
  end

  def reserve_held_cents
    attributes[:reserve_cents]
  end

  def reserve_adjustments
    @reserve_adjustments ||= event.balance_adjustments.effective.where(kind: RESERVE_KINDS).order(:id).to_a
  end

  # Reserve holds that are still posted (not reversed). After the 30-day
  # release the hold stays posted and the release offsets it.
  def active_holds
    reserve_adjustments.select { |adjustment| adjustment.kind == "reserve_hold" && adjustment.status_posted? && adjustment.reversal_of_id.nil? }
  end

  def reserve_hold_posted?
    active_holds.any?
  end

  # An administrator chose to finalize without the standard reserve
  # (PayoutReserves.skip!). The audit record is the durable decision.
  def reserve_skipped?
    return @reserve_skipped if defined?(@reserve_skipped)

    @reserve_skipped = AuditLog.where(auditable_type: "Event", auditable_id: event.id, action: SKIP_ACTION).exists?
  end

  def reserve_released_cents
    reserve_adjustments.select do |adjustment|
      adjustment.kind == "reserve_release" && adjustment.status_posted? && adjustment.reversal_of_id.nil?
    end.sum(&:amount_cents)
  end

  def reserve_held_on
    reserve_adjustments.select { |adjustment| adjustment.kind == "reserve_hold" }.map(&:effective_at).min
  end

  def payouts
    @payouts ||= event.payouts.order(:id).to_a
  end

  def paid_cents
    payouts.select(&:status_paid?).sum(&:amount_cents)
  end

  def in_flight_cents
    payouts.select { |payout| IN_FLIGHT_STATUSES.include?(payout.status) }.sum(&:amount_cents)
  end

  def in_flight_payout
    payouts.reverse.find { |payout| IN_FLIGHT_STATUSES.include?(payout.status) }
  end

  def owed_cents
    balance_before_payout_cents - paid_cents - in_flight_cents
  end

  def latest_settlement
    @latest_settlement ||= event.settlements.status_finalized.order(version: :desc).first
  end

  # A finalized version PayoutCreator would accept now.
  def payable_settlement
    settlement = latest_settlement
    settlement if settlement && settlement.source_digest == attributes[:source_digest]
  end

  def money_blocker
    return @money_blocker if defined?(@money_blocker)

    @money_blocker = Settlements::Finalizer.open_money_blocker(event)
  end

  def money_activity?
    attributes[:gross_cents].positive? || attributes[:refund_cents].positive? || reserve_adjustments.any? ||
      attributes[:adjustment_cents].nonzero? || payouts.any?
  end

  def first_transfer_sent?
    payouts.any?(&:status_paid?)
  end

  # A payout is pending, processing, held or paid for this event.
  def payout_committed?
    payouts.any? { |payout| COMMITTED_STATUSES.include?(payout.status) }
  end

  # What the organizer can still expect, counting the reserve that comes back
  # on its release date. Negative: they owe it even after the reserve.
  def still_to_come_cents
    owed_cents + reserve_held_cents
  end

  def reserve_suggested?
    !payout_committed? && !reserve_hold_posted? && !reserve_skipped? && suggested_reserve_cents.positive? &&
      event.completed?
  end

  # One step at a time, in the order finance does them. Each step names the
  # action that moves the event forward.
  def next_step
    return "sales_open" unless ended?
    return "complete_event" unless event.completed? || event.cancelled? || event.archived?
    return "record_transfer" if in_flight_payout
    return "resolve_money" if money_blocker && (owed_cents.positive? || reserve_held_cents.positive?)
    return "hold_reserve" if reserve_suggested?
    if owed_cents.positive?
      return payable_settlement && payable_settlement.available_to_payout_cents.positive? ? "send_transfer" : "finalize_statement"
    end
    return reserve_release_due? ? "release_reserve" : "wait_for_reserve" if reserve_held_cents.positive?
    return "negative_balance" if owed_cents.negative?

    "done"
  end

  # Every action an administrator may take now, so the due screen can offer a
  # secondary choice (for example finalizing without a reserve). The services
  # recheck each one under their locks.
  def available_actions
    closed = event.completed? || event.cancelled?
    actions = []
    return actions unless closed

    actions << "record_transfer" if in_flight_payout
    return actions if money_blocker

    actions << "hold_reserve" if !reserve_hold_posted? && !payout_committed? && suggested_reserve_cents.positive? &&
      event.completed?
    actions << "finalize_statement" if !payable_settlement && owed_cents.positive?
    actions << "send_transfer" if !in_flight_payout && payable_settlement&.available_to_payout_cents.to_i.positive? &&
      owed_cents.positive?
    actions << "release_reserve" if reserve_held_cents.positive?
    actions
  end

  # When the current step should be done, in the event's calendar.
  def due_on
    case next_step
    when "hold_reserve", "finalize_statement", "send_transfer", "record_transfer", "complete_event", "resolve_money"
      reserve_released_cents.positive? ? remainder_due_on : transfer_due_on
    when "release_reserve", "wait_for_reserve"
      reserve_release_on
    end
  end

  def overdue_business_days
    due = due_on
    return 0 unless due

    PayoutCalendar.business_days_between(due, today)
  end

  def due_state
    due = due_on
    return "none" unless due
    return "overdue" if today > due
    return "upcoming" if next_step == "wait_for_reserve"

    "due"
  end
end
