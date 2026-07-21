# frozen_string_literal: true

module LivePilotMetrics
  class Manager
    class MetricError < StandardError; end

    EXTERNAL_FIELDS = %w[
      provider_healthy provider_status_reference checkout_p95_ms scanner_sync_lag_seconds
      support_contacts_count refund_request_count support_coverage_confirmed guam_communications_current
    ].freeze

    def self.record!(run:, actor:, attributes:, request: nil)
      validate_admin!(actor)
      snapshot = nil
      run.event.with_lock do
        run.lock!
        raise MetricError, "Monitoring checkpoints require an open pilot run" unless
          run.status_active? || run.status_paused?
        external = normalize_external(attributes[:external_metrics])
        validate_external!(external)
        local = local_metrics(run)
        breaches = threshold_breaches(run.live_pilot_review.thresholds, local, external)
        snapshot = run.live_pilot_metric_snapshots.create!(
          event: run.event, recorded_by_user: actor, local_metrics: local, external_metrics: external,
          breached_thresholds: breaches, evidence_reference: attributes[:evidence_reference].to_s.strip,
          evidence_digest: attributes[:evidence_digest].to_s.strip,
          observed_at: observation_time(attributes[:observed_at], run: run)
        )
        audit!(snapshot, actor, request)
        if breaches.any? && run.status_active?
          LivePilotRuns::Manager.pause!(
            run: run, actor: actor, reason: "Monitoring threshold breached: #{breaches.keys.join(', ')}",
            request: request
          )
        end
      end
      snapshot
    rescue ActiveRecord::RecordInvalid, ActiveRecord::StatementInvalid => e
      raise MetricError, error_message(e)
    rescue LivePilotRuns::Manager::RunError => e
      raise MetricError, e.message
    end

    def self.local_metrics(run)
      event = run.event
      orders = event.orders
      payments = Payment.joins(:order).where(orders: { event_id: event.id })
      refunds = Refund.joins(:order).where(orders: { event_id: event.id })
      holds = event.inventory_holds
      deliveries = event.message_deliveries
      checkout_started = event.marketplace_funnel_events.where(stage: :checkout_started).count
      purchases = orders.where(status: [:completed, :partially_refunded, :refunded]).count
      online_purchases = orders.where(status: [:completed, :partially_refunded, :refunded])
        .where("source IS NULL OR source <> ?", "box_office").count
      payment_count = payments.where.not(status: :pending).count
      payment_failures = payments.where(status: [:failed, :cancelled]).count
      hold_count = holds.count
      expired_holds = holds.where(status: :expired).count
      delivery_count = deliveries.count
      delivery_failures = deliveries.where(status: [:failed, :bounced, :complained]).count
      {
        "checkout_started_count" => checkout_started,
        "purchase_count" => purchases,
        "online_purchase_count" => online_purchases,
        "checkout_conversion_bps" => rate_bps(online_purchases, checkout_started),
        "payment_count" => payment_count,
        "payment_failure_count" => payment_failures,
        "payment_failure_rate_bps" => rate_bps(payment_failures, payment_count),
        "hold_count" => hold_count,
        "expired_hold_count" => expired_holds,
        "hold_expiry_rate_bps" => rate_bps(expired_holds, hold_count),
        "delivery_count" => delivery_count,
        "delivery_failure_count" => delivery_failures,
        "delivery_failure_rate_bps" => rate_bps(delivery_failures, delivery_count),
        "scanner_conflict_count" => event.admission_actions.where(result: :conflict).count,
        "pending_payment_count" => payments.where(status: :pending).count,
        "pending_refund_count" => refunds.where(status: :pending).count,
        "active_hold_count" => holds.active.where("expires_at > ?", Time.current).count,
        "open_reconciliation_exception_count" => ReconciliationException.joins(:order)
          .where(orders: { event_id: event.id }, status: :open).count,
        "unknown_card_payment_count" => event.card_present_payment_attempts.where(status: :result_unknown).count,
        "support_note_count" => event.support_notes.count,
        "unresolved_p0_p1_incident_count" => run.unresolved_incidents.where(severity: [:p0, :p1]).count,
        "committed_ticket_quantity" => LivePilot.committed_ticket_quantity(event),
        "inventory_cap" => run.inventory_cap
      }
    end

    def self.threshold_breaches(thresholds, local, external)
      values = thresholds.to_h.stringify_keys
      breaches = {}
      compare_minimum!(breaches, "checkout_conversion_bps", local["checkout_conversion_bps"],
        values["minimum_checkout_conversion_bps"], local["checkout_started_count"].positive?)
      compare_maximum!(breaches, "payment_failure_rate_bps", local["payment_failure_rate_bps"],
        values["maximum_payment_failure_rate_bps"])
      compare_maximum!(breaches, "hold_expiry_rate_bps", local["hold_expiry_rate_bps"],
        values["maximum_hold_expiry_rate_bps"])
      compare_maximum!(breaches, "delivery_failure_rate_bps", local["delivery_failure_rate_bps"],
        values["maximum_delivery_failure_rate_bps"])
      compare_maximum!(breaches, "scanner_conflict_count", local["scanner_conflict_count"],
        values["maximum_scanner_conflicts"])
      compare_maximum!(breaches, "scanner_sync_lag_seconds", external["scanner_sync_lag_seconds"],
        values["maximum_scanner_sync_lag_seconds"])
      compare_maximum!(breaches, "checkout_p95_ms", external["checkout_p95_ms"],
        values["maximum_checkout_p95_ms"])
      contacts_per_100 = local["purchase_count"].positive? ?
        (external["support_contacts_count"] * 100.0 / local["purchase_count"]).round : 0
      compare_maximum!(breaches, "support_contacts_per_100_orders", contacts_per_100,
        values["maximum_support_contacts_per_100_orders"])
      breaches["provider_health"] = { observed: false, expected: true } unless external["provider_healthy"]
      breaches["support_coverage"] = { observed: false, expected: true } unless external["support_coverage_confirmed"]
      breaches["guam_communications"] = { observed: false, expected: true } unless external["guam_communications_current"]
      %w[open_reconciliation_exception_count unknown_card_payment_count].each do |field|
        compare_maximum!(breaches, field, local[field], 0)
      end
      breaches
    end

    def self.normalize_external(value)
      result = value.respond_to?(:to_h) ? value.to_h.stringify_keys.slice(*EXTERNAL_FIELDS) : {}
      %w[provider_healthy support_coverage_confirmed guam_communications_current].each do |field|
        result[field] = ActiveModel::Type::Boolean.new.cast(result[field])
      end
      %w[checkout_p95_ms scanner_sync_lag_seconds support_contacts_count refund_request_count].each do |field|
        result[field] = Integer(result[field], exception: false) || result[field]
      end
      result
    end
    private_class_method :normalize_external

    def self.validate_external!(external)
      missing = EXTERNAL_FIELDS.reject { |field| external.key?(field) && !external[field].nil? }
      raise MetricError, "Monitoring checkpoint must include: #{missing.join(', ')}" if missing.any?
      raise MetricError, "A provider status evidence reference is required" if external["provider_status_reference"].blank?
      numeric = %w[checkout_p95_ms scanner_sync_lag_seconds support_contacts_count refund_request_count]
      raise MetricError, "Monitoring counts and latency must be non-negative integers" unless
        numeric.all? { |field| external[field].is_a?(Integer) && external[field] >= 0 }
    end
    private_class_method :validate_external!

    def self.compare_minimum!(breaches, key, observed, expected, applicable = true)
      return unless applicable && observed < expected.to_i

      breaches[key] = { observed: observed, minimum: expected.to_i }
    end
    private_class_method :compare_minimum!

    def self.compare_maximum!(breaches, key, observed, expected)
      return unless observed > expected.to_i

      breaches[key] = { observed: observed, maximum: expected.to_i }
    end
    private_class_method :compare_maximum!

    def self.rate_bps(numerator, denominator)
      denominator.positive? ? (numerator * 10_000.0 / denominator).round : 0
    end
    private_class_method :rate_bps

    def self.observation_time(value, run:)
      parsed = value.blank? ? Time.current : Time.iso8601(value.to_s)
      raise MetricError, "Checkpoint time cannot predate the pilot run" if parsed < run.started_at
      raise MetricError, "Checkpoint time cannot be in the future" if parsed > Time.current

      parsed
    rescue ArgumentError
      raise MetricError, "Checkpoint time must be an ISO-8601 timestamp"
    end
    private_class_method :observation_time

    def self.validate_admin!(actor)
      raise MetricError, "Only an administrator can record Gate I monitoring" unless actor&.admin?
    end
    private_class_method :validate_admin!

    def self.audit!(snapshot, actor, request)
      AuditLogger.record!(
        action: "live_pilot_metrics.recorded", auditable: snapshot, actor: actor,
        organization: snapshot.event.organization,
        after_data: snapshot.attributes.slice(
          "id", "live_pilot_run_id", "event_id", "local_metrics", "external_metrics",
          "breached_thresholds", "evidence_reference", "evidence_digest", "observed_at"
        ), request: request
      )
    end
    private_class_method :audit!

    def self.error_message(error)
      return error.record.errors.full_messages.to_sentence if error.respond_to?(:record)

      error.message.presence || "The monitoring checkpoint could not be recorded"
    end
    private_class_method :error_message
  end
end
