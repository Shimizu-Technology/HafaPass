# frozen_string_literal: true

class EventCancellationRefunds
  PAID_STATUSES = [:completed, :partially_refunded, :refunded].freeze

  # A recorded manual return is a succeeded Refund, so it is included once
  # in the succeeded-refund total.
  def self.balance_cents(order)
    captured_payments = order.payments.where(status: [:succeeded, :partially_refunded, :refunded])
    captured_payments = captured_payments.merge(Payment.live_or_legacy_capture) if Rails.env.production?
    captured = captured_payments.sum(:amount_cents)
    refunds = order.refunds.where(status: [:pending, :succeeded])
    disputes = order.disputes.lost
    if Rails.env.production?
      refunds = refunds.where(payment_id: captured_payments.select(:id))
      disputes = disputes.where(payment_id: captured_payments.select(:id))
    end
    reserved_or_returned = refunds.sum(:amount_cents)
    chargebacks = disputes.sum(:amount_cents)
    [captured - reserved_or_returned - chargebacks, 0].max
  end

  def self.outstanding_balance_cents(event)
    liability_snapshot(event)[:outstanding_cents]
  end

  def self.unresolved?(event)
    event.cancelled? && liability_snapshot(event)[:unresolved]
  end

  def self.liability_snapshot(event)
    entries = balances(event, exclude_nonlive: true)
    { outstanding_cents: entries.sum { |entry| entry[:amount_cents] },
      unresolved: entries.any? { |entry| entry[:amount_cents].positive? || entry[:pending_refund] || entry[:open_dispute] } }
  end

  def self.balances(event, exclude_nonlive: Rails.env.production?)
    rows = event.orders.where(status: PAID_STATUSES).order(:id).pluck(:id, :payment_method)
    ids = rows.map(&:first)
    return [] if ids.empty?

    captured_statuses = Payment.statuses.values_at("succeeded", "partially_refunded", "refunded").join(", ")
    capture_filter = "status IN (#{captured_statuses})"
    if exclude_nonlive
      capture_filter += " AND (provider_environment = 'live' OR (provider_environment IS NULL AND " \
        "provider_payload->>'livemode' IS DISTINCT FROM 'false' AND provider_payload->>'simulated' IS DISTINCT FROM 'true'))"
    end
    payments = Payment.where(order_id: ids).group(:order_id).pluck(:order_id,
      Arel.sql("COALESCE(SUM(amount_cents) FILTER (WHERE #{capture_filter}), 0)"),
      Arel.sql("COALESCE(BOOL_OR(provider = 'stripe' AND (provider_environment IN ('test', 'simulate') OR (provider_environment IS NULL AND (provider_payload->>'livemode' = 'false' OR provider_payload->>'simulated' = 'true')))), false)"),
      Arel.sql("COALESCE(BOOL_OR(status IN (#{captured_statuses}) AND (provider_environment = 'live' OR (provider_environment IS NULL AND provider_payload->>'livemode' IS DISTINCT FROM 'false' AND provider_payload->>'simulated' IS DISTINCT FROM 'true'))), false)"))
      .index_by(&:first)
    if exclude_nonlive
      rows.reject! { |id, _method| payments[id]&.at(2) && !payments[id]&.at(3) }
      ids = rows.map(&:first)
      return [] if ids.empty?
    end

    refund_statuses = Refund.statuses.values_at("pending", "succeeded").join(", ")
    live_payment_ids = Payment.live_or_legacy_capture.select(:id)
    refund_scope = Refund.where(order_id: ids)
    refund_scope = refund_scope.where(payment_id: live_payment_ids) if exclude_nonlive
    refunds = refund_scope.group(:order_id).pluck(:order_id,
      Arel.sql("COALESCE(SUM(amount_cents) FILTER (WHERE status IN (#{refund_statuses})), 0)"),
      Arel.sql("COALESCE(BOOL_OR(status = #{Refund.statuses.fetch('pending')}), false)"))
      .index_by(&:first)
    dispute_scope = Dispute.where(order_id: ids)
    dispute_scope = dispute_scope.where(payment_id: live_payment_ids) if exclude_nonlive
    disputes = dispute_scope.group(:order_id).pluck(:order_id,
      Arel.sql("COALESCE(SUM(amount_cents) FILTER (WHERE status = #{Dispute.statuses.fetch('lost')}), 0)"),
      Arel.sql("COALESCE(BOOL_OR(status = #{Dispute.statuses.fetch('open')}), false)"))
      .index_by(&:first)
    rows.map do |id, method|
      lost_cents = disputes[id]&.at(1) || 0
      { order_id: id, payment_method: method,
        captured_cents: payments[id]&.at(1) || 0,
        amount_cents: [(payments[id]&.at(1) || 0) - (refunds[id]&.at(1) || 0) - lost_cents, 0].max,
        pending_refund: refunds[id]&.at(2) || false, open_dispute: disputes[id]&.at(2) || false,
        lost_dispute: lost_cents.positive? }
    end
  end

  # Caller holds the order and item locks (and the organization lock first).
  def self.refresh_cash_item!(item, actor:)
    return unless item.needs_manual?

    amount = balance_cents(item.order)
    if amount != item.amount_cents
      previous_amount = item.amount_cents
      item.update!(amount_cents: amount)
      event = item.event_cancellation_refund_run.event
      AuditLogger.record!(action: "event.cancellation_refund_amount_changed", auditable: event,
        actor: actor, organization: event.organization,
        metadata: { order_id: item.order_id, previous_amount_cents: previous_amount, amount_cents: amount })
    end
    if item.order.refunds.pending.exists?
      item.update!(status: :waiting_on_pending_refund, last_error: "Waiting for an existing refund")
    elsif amount.zero?
      item.update!(status: :skipped, last_error: "Buyer balance already resolved")
    end
    amount
  end

  def self.preview(event)
    refundable = balances(event).select { |entry| entry[:amount_cents].positive? }
    { count: refundable.length, total_cents: refundable.sum { |entry| entry[:amount_cents] },
      cash_count: refundable.count { |entry| entry[:payment_method] == "door_cash" } }
  end

  def self.prepare!(event:, actor:)
    run = event.event_cancellation_refund_run || event.create_event_cancellation_refund_run!(started_by: actor)
    hold_payouts!(event, actor: actor)
    balances(event).each do |entry|
      amount = entry[:amount_cents]
      status = if entry[:open_dispute]
        :waiting_on_dispute
      elsif entry[:pending_refund]
        :waiting_on_pending_refund
      elsif amount.zero?
        :skipped
      elsif entry[:payment_method] == "door_cash"
        :needs_manual
      else
        :pending
      end
      run.items.find_or_create_by!(order_id: entry[:order_id]) do |item|
        item.amount_cents = amount
        item.status = status
        item.last_error = "Waiting for dispute resolution" if entry[:open_dispute]
        item.last_error = "Dispute lost; buyer refunded by chargeback" if entry[:lost_dispute] && amount.zero? && !entry[:pending_refund]
        item.last_error = "Waiting for an existing refund" if status == :waiting_on_pending_refund
        if status == :skipped && !entry[:lost_dispute]
          item.last_error = entry[:captured_cents].zero? ? "No payment to refund" : "Order already fully refunded"
        end
      end
    end
    AuditLogger.record!(action: "event.cancellation_refunds_started", auditable: event, actor: actor,
      organization: event.organization, metadata: preview(event))
    run
  end

  def self.hold_payouts!(event, actor:)
    event.payouts.where(status: [:pending, :processing]).find_each do |payout|
      payout.with_lock do
        next unless payout.status_pending? || payout.status_processing?

        before_data = payout.attributes.slice("status", "failure_code", "failure_message")
        preserve_code = %w[provider_result_conflict provider_result_unknown].include?(payout.failure_code)
        hold_message = "Hold payment while cancellation refunds are unresolved"
        hold_message += "; provider result remains unknown" if payout.failure_code == "provider_result_unknown"
        payout.update!(status: :held, held_from_status: payout.status,
          failure_code: preserve_code ? payout.failure_code : "event_cancellation",
          failure_message: hold_message)
        AuditLogger.record!(action: "payout.held_for_cancellation", auditable: payout, actor: actor,
          organization: event.organization, before_data: before_data,
          after_data: payout.attributes.slice("status", "failure_code", "failure_message"),
          metadata: { event_id: event.id })
      end
    end
  end
end
