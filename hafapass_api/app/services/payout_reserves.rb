# frozen_string_literal: true

# Posts the standard chargeback reserve for one event and releases it after
# 30 days. Both are ordinary reserve balance adjustments, so the settlement
# calculator, statements, payout balance and every existing payout guard see
# them exactly as they see a hand-entered reserve. Neither moves money.
#
# Locks follow docs/LOCKING.md: organization (FOR UPDATE, matching
# BalanceAdjustmentsController, PayoutCreator and Settlements::Finalizer),
# then the event row. Both are rechecked after the locks are held.
class PayoutReserves
  class ReserveError < StandardError; end

  MIN_EARLY_REASON_LENGTH = 10

  def self.hold!(**)
    new(**).hold!
  end

  def self.release!(**)
    new(**).release!
  end

  def initialize(event:, actor:, amount_cents: nil, note: nil, early_release_reason: nil, request: nil)
    @event = event
    @actor = actor
    @amount_cents = amount_cents
    @note = note.to_s.strip.presence
    @early_release_reason = early_release_reason.to_s.strip.presence
    @request = request
  end

  def hold!
    authorize!
    with_locks do |schedule|
      raise ReserveError, "Complete the event before holding its reserve" unless event.completed?
      raise ReserveError, "A reserve is already held for this event" if schedule.reserve_hold_posted?
      raise ReserveError, "This event's first transfer was already sent" if schedule.first_transfer_sent?
      if (blocker = schedule.money_blocker)
        raise ReserveError, "#{blocker} before holding the reserve"
      end

      net = schedule.net_before_reserve_cents
      suggested = schedule.suggested_reserve_cents
      amount = requested_amount(suggested)
      raise ReserveError, "There are no platform-held proceeds to reserve" unless net.positive?
      raise ReserveError, "Reserve must be a positive amount" unless amount.positive?
      raise ReserveError, "Reserve cannot be more than the event's net proceeds" if amount > net

      release_on = schedule.reserve_release_on
      reason = "Chargeback reserve: #{percent_label(amount, net)} of #{money(net)} net proceeds, " \
        "held until #{release_on.iso8601}"
      reason += ". #{note}" if note
      post!(kind: "reserve_hold", amount_cents: -amount, reason: reason,
        metadata: { reserve_rate_bps: PayoutSchedule::RESERVE_RATE_BPS, net_before_reserve_cents: net,
          suggested_reserve_cents: suggested, reserve_cents: amount, release_on: release_on.iso8601,
          amount_overridden: amount != suggested })
    end
  end

  def release!
    authorize!
    with_locks do |schedule|
      held = schedule.reserve_held_cents
      raise ReserveError, "No reserve is held for this event" unless held.positive?
      if (blocker = schedule.money_blocker)
        raise ReserveError, "#{blocker} before releasing the reserve"
      end

      release_on = schedule.reserve_release_on
      early = release_on.nil? || schedule.today < release_on
      if early && early_release_reason.to_s.length < MIN_EARLY_REASON_LENGTH
        raise ReserveError, "The reserve is held until #{release_on&.iso8601 || "30 days after the event"}. " \
          "To release it early, give a reason of at least #{MIN_EARLY_REASON_LENGTH} characters"
      end
      unless BackupWithholding.safe_text?(early_release_reason)
        raise ReserveError, BackupWithholding::TIN_WARNING
      end

      reason = "Chargeback reserve released#{early ? " early: #{early_release_reason}" : " after #{PayoutSchedule::RESERVE_DAYS} days"}"
      post!(kind: "reserve_release", amount_cents: held, reason: reason,
        metadata: { reserve_cents: held, release_on: release_on&.iso8601, early: early,
          early_release_reason: early ? early_release_reason : nil, owed_before_release_cents: schedule.owed_cents }.compact)
    end
  end

  private

  attr_reader :event, :actor, :amount_cents, :note, :early_release_reason, :request

  def authorize!
    raise ReserveError, "Administrator access is required" unless actor&.persisted? && actor.admin?
    raise ReserveError, BackupWithholding::TIN_WARNING unless BackupWithholding.safe_text?(note)
  end

  def with_locks
    BalanceAdjustment.transaction do
      event.organization.lock!
      event.lock!
      yield PayoutSchedule.for(event)
    end
  end

  def requested_amount(suggested)
    return suggested if amount_cents.nil? || amount_cents.to_s.strip.empty?
    raise ReserveError, "Reserve must be whole cents" unless amount_cents.to_s.match?(/\A\d+\z/)

    amount_cents.to_i
  end

  def post!(kind:, amount_cents:, reason:, metadata:)
    organization = event.organization
    adjustment = organization.balance_adjustments.create!(event: event, created_by_user: actor, kind: kind,
      amount_cents: amount_cents, currency: organization.currency, status: :posted, reason: reason,
      effective_at: Time.current)
    AuditLogger.record!(action: "balance_adjustment.posted", auditable: adjustment, actor: actor,
      organization: organization, event: event,
      after_data: adjustment.attributes.slice("id", "event_id", "kind", "amount_cents", "currency", "status", "reason"),
      metadata: metadata.merge(source: "payout_schedule"), request: request)
    adjustment
  rescue ActiveRecord::RecordInvalid => e
    raise ReserveError, e.record.errors.full_messages.to_sentence
  end

  def percent_label(amount, net)
    basis_points = ((amount * 10_000) + (net / 2)) / net
    whole, fraction = basis_points.divmod(100)
    fraction.zero? ? "#{whole}%" : format("%<whole>d.%<fraction>02d%%", whole: whole, fraction: fraction).sub(/0+%\z/, "%")
  end

  def money(cents)
    ActiveSupport::NumberHelper.number_to_currency(BigDecimal(cents) / 100)
  end
end
