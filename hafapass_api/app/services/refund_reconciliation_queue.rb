# frozen_string_literal: true

class RefundReconciliationQueue
  STATUSES = %w[pending failed cancelled needs_manual waiting_on_pending_refund waiting_on_dispute request_unexecuted dispute_open provider_review].freeze
  PAGE_SIZE = 50

  def self.call(**options)
    new(**options).call
  end

  def self.outstanding_for_event?(event)
    new(event_id: event.id).entries.any?
  end

  def self.recovery_amount_for_event(event)
    return 0 unless event.cancelled? && event.payouts.status_paid.exists?

    new(event_id: event.id).entries.sum { |entry| entry[:amount_cents] }
  end

  def initialize(event_id: nil, organization_id: nil, status: nil, age_days: nil, page: 1, per_page: PAGE_SIZE)
    @event_id = event_id
    @organization_id = organization_id
    @status = status.to_s
    @age_days = age_days.to_i if age_days.present?
    @page = [page.to_i, 1].max
    @per_page = per_page.to_i.clamp(1, 100)
  end

  def call
    all = entries
    all.select! { |entry| entry[:status] == @status } if STATUSES.include?(@status)
    all.select! { |entry| entry[:age_seconds] >= @age_days.days.to_i } if @age_days && @age_days.positive?
    all.sort_by! { |entry| [-entry[:age_seconds], entry[:type], entry[:id]] }
    total = all.length
    { items: all.slice((@page - 1) * @per_page, @per_page) || [],
      meta: { page: @page, per_page: @per_page, total: total, total_pages: (total.to_f / @per_page).ceil } }
  end

  def entries
    @entries ||= build_entries
  end

  private

  def order_scope
    scope = Order.all
    scope = scope.where(event_id: @event_id) if @event_id.present?
    scope = scope.where(event_id: Event.where(organization_id: @organization_id).select(:id)) if @organization_id.present?
    scope
  end

  def build_entries
    ids = order_scope.select(:id)
    @paid_event_ids = Payout.status_paid.where(event_id: order_scope.select(:event_id)).pluck(:event_id).to_set
    live_payment_ids = Payment.live_or_legacy_capture.where(order_id: ids).pluck(:id).to_set if Rails.env.production?
    includes = { order: [:refunds, :disputes, :payments, { event: :organization }] }
    cancellation = EventCancellationRefundItem.where(order_id: ids)
      .where(status: [:pending, :failed, :needs_manual, :waiting_on_pending_refund, :waiting_on_dispute])
      .includes(includes, :event_cancellation_refund_run).to_a
    cancellation.select! { |item| item.order.payments.any? { |payment| live_payment_ids.include?(payment.id) } } if live_payment_ids
    cancellation_order_ids = cancellation.map(&:order_id).to_set
    refunds = Refund.where(order_id: ids, status: [:pending, :failed, :cancelled]).includes(includes, :payment).to_a
    refunds.select! { |refund| live_payment_ids.include?(refund.payment_id) } if live_payment_ids
    retry_parent_ids = refunds.map(&:order).uniq.flat_map(&:refunds).filter_map do |refund|
      refund.idempotency_key[%r{\Arefund-reconciliation/(\d+)\z}, 1]&.to_i
    end.to_set
    responses = EventChangeResponse.where(order_id: ids, decision: "refund_requested")
      .includes(includes, :event_change).to_a
    responses.select! { |response| response.order.payments.any? { |payment| live_payment_ids.include?(payment.id) } } if live_payment_ids
    disputes = Dispute.open.where(order_id: ids).includes(includes).to_a
    disputes.select! { |dispute| live_payment_ids.include?(dispute.payment_id) } if live_payment_ids

    rows = cancellation.filter_map do |item|
      order = item.order
      applicable_refunds = live_payment_ids ? order.refunds.select { |refund| live_payment_ids.include?(refund.payment_id) } : order.refunds
      applicable_disputes = live_payment_ids ? order.disputes.select { |dispute| live_payment_ids.include?(dispute.payment_id) } : order.disputes
      pending = applicable_refunds.any?(&:pending?)
      open_dispute = applicable_disputes.any?(&:open?)
      captured = order.payments.select { |payment| (!live_payment_ids || live_payment_ids.include?(payment.id)) &&
        (payment.succeeded? || payment.partially_refunded? || payment.refunded?) }
        .sum(&:amount_cents)
      reserved = applicable_refunds.select { |refund| refund.pending? || refund.succeeded? }.sum(&:amount_cents)
      lost = applicable_disputes.select(&:lost?).sum(&:amount_cents)
      remaining = [captured - reserved - lost, 0].max
      next if remaining.zero? && !pending && !open_dispute

      row(item, "cancellation", item.status, pending || open_dispute ? item.amount_cents : remaining,
        item.last_error.presence || "Event cancelled", manual_type(order, item))
    end
    remaining_by_order = {}
    refunds.sort_by { |refund| [-refund.created_at.to_i, -refund.id] }.each do |refund|
      next if cancellation_order_ids.include?(refund.order_id) || retry_parent_ids.include?(refund.id)
      remaining = remaining_by_order.fetch(refund.order_id) { refund.order.refundable_cents }
      amount = refund.pending? ? refund.amount_cents : [refund.amount_cents, remaining].min
      next if amount.zero?
      remaining_by_order[refund.order_id] = [remaining - amount, 0].max unless refund.pending?

      rows << row(refund, "refund", refund.status, amount,
        refund.failure_message.presence || refund.reason.presence || "Stripe refund", nil)
    end
    responses.each do |response|
      next if cancellation_order_ids.include?(response.order_id)
      next if response.order.refunds.any? { |refund| refund.reason == "event_change_refund" }
      next if response.order.refundable_cents.zero?

      rows << row(response, "request", "request_unexecuted", response.order.refundable_cents,
        "Buyer requested a refund after an event change", nil)
    end
    disputes.each do |dispute|
      next if cancellation_order_ids.include?(dispute.order_id)

      rows << row(dispute, "dispute", "dispute_open", dispute.amount_cents,
        dispute.reason.presence || "Payment dispute is open", nil)
    end
    issues = ReconciliationException.open.where(order_id: ids,
      code: Commerce::ExternalRefundRecovery::RECOVERABLE_CODES).includes(includes, :payment).to_a
    issues.select! { |issue| live_payment_ids.include?(issue.payment_id) } if live_payment_ids
    issues.each do |issue|
      rows << row(issue, "exception", "provider_review", issue.actual_amount_cents || issue.order.refundable_cents,
        "External Stripe refund needs verification", nil)
    end
    attach_unable_reasons(rows)
    rows
  end

  def manual_type(order, item)
    return nil unless item.needs_manual?
    return "cash" if order.payment_method == "door_cash"
    return "card" if order.payment_method == "door_card"

    nil
  end

  def row(record, type, status, amount, reason, manual)
    order = record.order
    event = order.event
    at = record.try(:responded_at) || record.try(:opened_at) || record.created_at
    age = [(Time.current - at).to_i, 0].max
    action = case status
    when "failed", "cancelled" then "Review and retry the Stripe refund"
    when "pending", "waiting_on_pending_refund" then "Check the provider refund status"
    when "needs_manual" then manual == "cash" ? "Return cash and record the receipt" : "Return the card payment and record the reference"
    when "waiting_on_dispute", "dispute_open" then "Review the dispute outcome"
    when "provider_review" then "Check Stripe status to retrieve and verify the refund operations"
    when "request_unexecuted" then "Review and issue the buyer refund"
    else "Review the refund"
    end
    organizer_already_paid = event.cancelled? && @paid_event_ids.include?(event.id)
    { id: record.id, type: type, order_id: order.id, order_reference: order.reference,
      buyer_name: order.buyer_name, buyer_email: order.buyer_email, event_id: event.id,
      event_title: event.title, organization_id: event.organization_id, organization_name: event.organization.name,
      amount_cents: amount, currency: order.currency, reason: reason, status: status,
      created_at: at, age_seconds: age, overdue: age > 3.days.to_i, next_action: action,
      manual_type: manual, organizer_already_paid: organizer_already_paid }
  end

  def attach_unable_reasons(rows)
    types = { "refund" => "Refund", "cancellation" => "EventCancellationRefundItem",
      "request" => "EventChangeResponse", "dispute" => "Dispute", "exception" => "ReconciliationException" }
    logs = AuditLog.where(action: "refund_reconciliation.unable", auditable_type: types.values,
      auditable_id: rows.map { |row| row[:id] }).order(:occurred_at, :id)
    reasons = logs.each_with_object({}) { |log, hash| hash[[log.auditable_type, log.auditable_id]] = log.metadata["reason"] }
    rows.each { |row| row[:unable_reason] = reasons[[types.fetch(row[:type]), row[:id]]] }
  end
end
