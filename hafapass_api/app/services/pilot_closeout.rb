# frozen_string_literal: true

require "digest"

class PilotCloseout
  class StateError < StandardError; end

  BLOCKING_ZERO_FIELDS = %w[
    pending_payment_count pending_refund_count open_dispute_count open_reconciliation_exception_count
    unknown_card_payment_count active_inventory_hold_count active_catalog_hold_count active_seat_hold_count
    pending_catalog_fulfillment_count queued_or_delayed_message_count active_scanner_device_count
    effective_staff_assignment_count unresolved_incident_count payout_in_flight_count
  ].freeze

  def self.pending_submission(run)
    decided_ids = run.pilot_closeout_reviews.where(decision: [:approval, :rejection]).select(:parent_review_id)
    run.pilot_closeout_reviews.decision_submission.where.not(id: decided_ids).order(created_at: :desc).first
  end

  def self.latest_approval(run)
    run.pilot_closeout_reviews.decision_approval.order(created_at: :desc).first
  end

  def self.active_approval(run)
    revoked_ids = run.pilot_closeout_reviews.decision_revocation.select(:parent_review_id)
    run.pilot_closeout_reviews.decision_approval.where.not(id: revoked_ids)
      .where(local_state_digest: local_state_digest(run), application_revision: PilotReadiness.application_revision)
      .order(created_at: :desc).first
  end

  def self.status(event)
    run = event.live_pilot_runs.status_completed.order(completed_at: :desc).first
    approval = active_approval(run) if run
    latest = latest_approval(run) if run
    {
      required: run.present?, eligible: run.present?, completed_run: run,
      pending_submission: run && pending_submission(run), latest_approval: latest,
      active_approval_id: approval&.id, approved: approval.present?,
      local_metrics: run && local_metrics(run), application_revision: PilotReadiness.application_revision
    }
  end

  def self.list_summary(event)
    run = event.live_pilot_runs.to_a.select(&:status_completed?).max_by(&:completed_at)
    return { eligible: false, approved: false } unless run

    reviews = event.pilot_closeout_reviews.to_a.select { |review| review.live_pilot_run_id == run.id }
    decided_ids = reviews.filter_map do |review|
      review.parent_review_id if review.decision_approval? || review.decision_rejection?
    end
    revoked_ids = reviews.filter_map { |review| review.parent_review_id if review.decision_revocation? }
    pending = reviews.select do |review|
      review.decision_submission? && !decided_ids.include?(review.id)
    end.max_by(&:created_at)
    latest = reviews.select(&:decision_approval?).max_by(&:created_at)
    approved = latest.present? && !revoked_ids.include?(latest.id) &&
      latest.local_state_digest == local_state_digest(run) &&
      latest.application_revision == PilotReadiness.application_revision
    {
      eligible: true, approved: approved, expansion_decision: (latest.expansion_decision if approved),
      pending_submission: pending && { id: pending.id, created_at: pending.created_at },
      approval_recorded: latest.present?, completed_run_id: run.id
    }
  end

  def self.ensure_closeout_ready!(run, metrics = nil)
    raise StateError, "Gate J requires a completed Gate I run" unless run&.status_completed?

    metrics ||= local_metrics(run)
    nonzero = BLOCKING_ZERO_FIELDS.select { |field| metrics[field].to_i != 0 }
    if nonzero.any?
      raise StateError, "Resolve local closeout blockers first: #{nonzero.join(', ')}"
    end
    if metrics["financial_activity"] && !metrics["settlement_current"]
      raise StateError, "Finalize a settlement for the current financial state before Gate J"
    end
    if metrics["financial_activity"] && metrics["payout_variance_cents"].to_i != 0
      raise StateError, "Paid payouts must reconcile exactly to the current settlement"
    end

    true
  end

  def self.metric_report(review)
    local = review.local_metrics.to_h.stringify_keys
    outcomes = review.outcome_metrics.to_h.stringify_keys
    orders = local["completed_order_count"].to_i
    local.merge(outcomes).merge(
      "support_contacts_per_100_orders" => orders.positive? ?
        (outcomes["support_contacts_count"].to_i * 100.0 / orders).round(1) : 0
    )
  end

  def self.local_state_digest(run, metrics = nil)
    metrics ||= local_metrics(run)
    Digest::SHA256.hexdigest(JSON.generate(canonicalize(
      metrics: metrics, watermarks: state_relations(run.event, run).transform_values { |relation| watermark(relation) }
    )))
  end

  def self.local_metrics(run)
    event = run.event
    orders = event.orders
    settled_orders = orders.where(status: [:completed, :partially_refunded, :refunded])
    order_ids = settled_orders.select(:id)
    order_items = OrderItem.where(order_id: order_ids)
    payments = Payment.joins(:order).where(orders: { event_id: event.id })
    refunds = Refund.where(order_id: orders.select(:id))
    disputes = Dispute.where(order_id: orders.select(:id))
    payouts = event.payouts
    settlement = event.settlements.status_finalized.order(version: :desc).first
    current_settlement = Settlements::Calculator.call(event).attributes
    checkout_started = event.marketplace_funnel_events.checkout_started.count
    purchases = settled_orders.count
    online_purchases = settled_orders.where("source IS NULL OR source <> ?", "box_office").count
    abandonment_count = [checkout_started - online_purchases, 0].max
    valid_tickets = event.tickets.where.not(status: :cancelled).count
    admitted_tickets = net_admitted_ticket_count(event)
    refund_durations = durations(refunds.succeeded.where.not(succeeded_at: nil), :created_at, :succeeded_at)
    payout_durations = payout_durations(payouts.status_paid)
    attributions = AcquisitionAttribution.where(order_id: order_ids)
    messages = message_scope(event)
    support_notes = support_scope(event)
    paid_payout_cents = payouts.status_paid.sum(:amount_cents)
    expected_payout_cents = settlement&.payable_cents.to_i
    financial_activity = settled_orders.where("total_cents > 0").exists? || refunds.exists? || disputes.exists?

    {
      "completed_order_count" => purchases,
      "ticket_quantity" => order_items.item_ticket.sum(:quantity),
      "add_on_quantity" => order_items.where.not(item_kind: OrderItem.item_kinds[:ticket]).sum(:quantity),
      "gross_sales_cents" => settled_orders.sum(:subtotal_cents),
      "discount_cents" => settled_orders.sum(:discount_cents),
      "tax_cents" => order_items.sum(:tax_cents),
      "buyer_service_fee_cents" => settled_orders.sum(:service_fee_cents),
      "organizer_fee_cents" => settled_orders.sum(:organizer_fee_cents),
      "total_charged_cents" => settled_orders.sum(:total_cents),
      "refund_cents" => refunds.succeeded.sum(:amount_cents),
      "dispute_count" => disputes.count,
      "dispute_lost_cents" => disputes.lost.sum(:amount_cents),
      "door_cash_order_count" => settled_orders.where(source: "box_office", payment_method: "door_cash").count,
      "door_cash_cents" => settled_orders.where(source: "box_office", payment_method: "door_cash").sum(:total_cents),
      "door_card_order_count" => settled_orders.where(source: "box_office", payment_method: "door_card").count,
      "door_card_cents" => settled_orders.where(source: "box_office", payment_method: "door_card").sum(:total_cents),
      "checkout_started_count" => checkout_started,
      "online_completed_order_count" => online_purchases,
      "checkout_conversion_bps" => rate_bps(online_purchases, checkout_started),
      "checkout_abandonment_count" => abandonment_count,
      "checkout_abandonment_bps" => rate_bps(abandonment_count, checkout_started),
      "valid_ticket_count" => valid_tickets,
      "admitted_ticket_count" => admitted_tickets,
      "no_show_count" => [valid_tickets - admitted_tickets, 0].max,
      "no_show_rate_bps" => rate_bps([valid_tickets - admitted_tickets, 0].max, valid_tickets),
      "admission_conflict_count" => event.admission_actions.result_conflict.count,
      "admission_rejection_count" => event.admission_actions.result_rejected.count,
      "message_exception_count" => messages.where(status: [:failed, :bounced, :complained]).count,
      "support_note_count" => support_notes.count,
      "refund_average_seconds" => average(refund_durations),
      "refund_max_seconds" => refund_durations.max.to_i,
      "payout_average_seconds" => average(payout_durations),
      "payout_max_seconds" => payout_durations.max.to_i,
      "attributed_order_count" => attributions.count,
      "partner_attributed_order_count" => attributions.where.not(distribution_link_id: nil).count,
      "referral_attributed_order_count" => attributions.where.not(event_referral_id: nil).count,
      "unattributed_order_count" => [purchases - attributions.count, 0].max,
      "settlement_id" => settlement&.id,
      "settlement_version" => settlement&.version,
      "settlement_source_digest" => settlement&.source_digest,
      "current_settlement_source_digest" => current_settlement[:source_digest],
      "settlement_current" => !financial_activity || settlement&.source_digest == current_settlement[:source_digest],
      "expected_payout_cents" => expected_payout_cents,
      "paid_payout_cents" => paid_payout_cents,
      "payout_variance_cents" => paid_payout_cents - expected_payout_cents,
      "financial_activity" => financial_activity,
      "pending_payment_count" => payments.pending.count,
      "pending_refund_count" => refunds.pending.count,
      "open_dispute_count" => disputes.open.count,
      "open_reconciliation_exception_count" => ReconciliationException.joins(:order)
        .where(orders: { event_id: event.id }, status: :open).count,
      "unknown_card_payment_count" => event.card_present_payment_attempts.status_result_unknown.count,
      "active_inventory_hold_count" => event.inventory_holds.active.where("expires_at > ?", Time.current).count,
      "active_catalog_hold_count" => CatalogItemHold.joins(:order)
        .where(orders: { event_id: event.id }, status: :active).where("catalog_item_holds.expires_at > ?", Time.current).count,
      "active_seat_hold_count" => active_seat_hold_count(event),
      "pending_catalog_fulfillment_count" => CatalogFulfillment.joins(order_item: :order)
        .where(orders: { event_id: event.id }, status: :pending).count,
      "queued_or_delayed_message_count" => messages.where(status: [:queued, :delayed]).count,
      "active_scanner_device_count" => event.scanner_devices.status_active.count,
      "effective_staff_assignment_count" => event.event_staff_assignments.effective.count,
      "unresolved_incident_count" => run.unresolved_incidents.count,
      "payout_in_flight_count" => payouts.where(status: [:pending, :processing]).count
    }
  end

  def self.state_relations(event, run)
    orders = event.orders
    order_ids = orders.select(:id)
    order_items = OrderItem.where(order_id: order_ids)
    {
      orders: orders, order_items: order_items, payments: Payment.where(order_id: order_ids),
      refunds: Refund.where(order_id: order_ids), disputes: Dispute.where(order_id: order_ids),
      fee_components: FeeComponent.where(order_id: order_ids),
      refund_items: RefundItem.where(refund_id: Refund.where(order_id: order_ids).select(:id)),
      tickets: event.tickets, admissions: event.admission_actions, messages: message_scope(event),
      support_notes: support_scope(event),
      reconciliation_exceptions: ReconciliationException.where(order_id: orders.select(:id)),
      settlements: event.settlements, payouts: event.payouts, card_attempts: event.card_present_payment_attempts,
      inventory_holds: event.inventory_holds,
      catalog_holds: CatalogItemHold.where(order_id: order_ids),
      catalog_fulfillments: CatalogFulfillment.where(order_item_id: order_items.select(:id)),
      scanner_devices: event.scanner_devices, staff_assignments: event.event_staff_assignments,
      funnel_events: event.marketplace_funnel_events, closeout_run_actions: run.live_pilot_run_actions,
      incidents: run.live_pilot_incidents, metric_snapshots: run.live_pilot_metric_snapshots
    }
  end
  private_class_method :state_relations

  def self.message_scope(event)
    MessageDelivery.where(event_id: event.id)
      .or(MessageDelivery.where(order_id: event.orders.select(:id)))
      .or(MessageDelivery.where(ticket_id: event.tickets.select(:id)))
  end
  private_class_method :message_scope

  def self.support_scope(event)
    SupportNote.where(event_id: event.id)
      .or(SupportNote.where(order_id: event.orders.select(:id)))
      .or(SupportNote.where(ticket_id: event.tickets.select(:id)))
  end
  private_class_method :support_scope

  def self.net_admitted_ticket_count(event)
    accepted = event.admission_actions.kind_admit.result_accepted.where.not(ticket_id: nil)
    reversed_ids = event.admission_actions.kind_reverse.result_accepted.where.not(reverses_action_id: nil)
      .select(:reverses_action_id)
    accepted.where.not(id: reversed_ids).distinct.count(:ticket_id)
  end
  private_class_method :net_admitted_ticket_count

  def self.active_seat_hold_count(event)
    configuration = event.event_seating_configuration
    return 0 unless configuration

    configuration.seat_hold_sessions.where(status: [:active, :claimed]).where("expires_at > ?", Time.current).count
  end
  private_class_method :active_seat_hold_count

  def self.durations(scope, start_field, end_field)
    scope.pluck(start_field, end_field).filter_map do |started_at, ended_at|
      [(ended_at - started_at).round, 0].max if started_at && ended_at
    end
  end
  private_class_method :durations

  def self.payout_durations(scope)
    scope.includes(:settlement).filter_map do |payout|
      start = payout.settlement.finalized_at || payout.settlement.calculated_at
      [(payout.paid_at - start).round, 0].max if start && payout.paid_at
    end
  end
  private_class_method :payout_durations

  def self.average(values)
    values.any? ? (values.sum.to_f / values.length).round : 0
  end
  private_class_method :average

  def self.rate_bps(numerator, denominator)
    denominator.positive? ? (numerator * 10_000.0 / denominator).round : 0
  end
  private_class_method :rate_bps

  def self.watermark(relation)
    { count: relation.count, maximum_id: relation.maximum(:id), maximum_updated_at: relation.maximum(:updated_at)&.iso8601(6) }
  end
  private_class_method :watermark

  def self.canonicalize(value)
    case value
    when Hash
      value.stringify_keys.sort.to_h.transform_values { |item| canonicalize(item) }
    when Array
      value.map { |item| canonicalize(item) }
    when Time, ActiveSupport::TimeWithZone, DateTime
      value.iso8601(6)
    when BigDecimal
      value.to_s("F")
    else
      value
    end
  end
  private_class_method :canonicalize
end
