# frozen_string_literal: true

module LivePilotRuns
  class Manager
    class RunError < StandardError; end

    COMPLETION_BOOLEAN_FIELDS = %w[
      all_operations_reconciled all_payment_outcomes_resolved all_refunds_resolved all_holds_reconciled
      all_deliveries_resolved all_scanner_devices_synced all_support_escalations_resolved
      guam_communications_complete no_unresolved_p0_or_p1
    ].freeze
    COMPLETION_ZERO_FIELDS = %w[
      unexplained_payment_variance_cents unexplained_inventory_variance unexplained_admission_variance
      unresolved_operation_exception_count
    ].freeze

    def self.start!(approval:, actor:, request: nil)
      validate_admin!(actor)
      run = nil
      approval.event.with_lock do
        approval.reload
        raise RunError, "A current approved Gate I plan is required" unless
          approval.decision_approval? && LivePilot.active_approval(approval.event)&.id == approval.id
        raise RunError, "Publish the approved pilot event before activating sales" unless approval.event.published?
        raise RunError, "This pilot plan has already been started" if approval.live_pilot_run
        raise RunError, "Another pilot run is already open for this event" if LivePilot.current_run(approval.event)

        run = approval.event.live_pilot_runs.create!(
          live_pilot_review: approval, started_by_user: actor, status: :active, started_at: Time.current
        )
        clear_gate_i_sales_suspension!(run.event)
        record_action!(run, :started, actor, { inventory_cap: run.inventory_cap }, request)
      end
      run
    rescue ActiveRecord::RecordInvalid, ActiveRecord::RecordNotUnique, ActiveRecord::StatementInvalid => e
      raise RunError, error_message(e)
    end

    def self.pause!(run:, actor:, reason:, request: nil)
      validate_admin!(actor)
      raise RunError, "A specific pause reason is required" if reason.to_s.strip.blank?
      run.event.with_lock do
        run.lock!
        raise RunError, "Only an active pilot run can be paused" unless run.status_active?

        now = Time.current
        reason = reason.to_s.strip
        run.update!(status: :paused, paused_at: now, pause_reason: reason)
        run.event.update!(sales_suspended_at: now, sales_suspension_reason: "[GATE I] #{reason}")
        record_action!(run, :paused, actor, { reason: reason }, request)
      end
      run
    rescue ActiveRecord::RecordInvalid, ActiveRecord::StatementInvalid => e
      raise RunError, error_message(e)
    end

    def self.resume!(run:, actor:, reason:, request: nil)
      validate_admin!(actor)
      raise RunError, "A specific resume reason is required" if reason.to_s.strip.blank?
      run.event.with_lock do
        run.lock!
        raise RunError, "Only a paused pilot run can be resumed" unless run.status_paused?
        raise RunError, "The Gate I approval is no longer current" unless
          LivePilot.active_approval(run.event)&.id == run.live_pilot_review_id
        raise RunError, "Resolve every pause-required incident before resuming" if
          run.unresolved_incidents.any?(&:pause_required?)
        checkpoint = run.live_pilot_metric_snapshots.order(observed_at: :desc).first
        if checkpoint.nil? || checkpoint.pause_required? || checkpoint.observed_at < run.paused_at ||
            checkpoint.created_at < run.paused_at
          raise RunError, "Record a post-pause safe monitoring checkpoint before resuming"
        end
        ensure_current_checkpoint_safe!(run, checkpoint)

        run.update!(status: :active, paused_at: nil, pause_reason: nil)
        clear_gate_i_sales_suspension!(run.event)
        record_action!(run, :resumed, actor, { reason: reason.to_s.strip }, request)
      end
      run
    rescue ActiveRecord::RecordInvalid, ActiveRecord::StatementInvalid => e
      raise RunError, error_message(e)
    end

    def self.complete!(run:, actor:, attributes:, request: nil)
      validate_admin!(actor)
      run.event.with_lock do
        run.lock!
        unless run.status_active? || run.status_paused?
          raise RunError, "Only an open pilot run can be completed"
        end
        raise RunError, "Mark the event completed before closing Gate I operations" unless run.event.completed?
        raise RunError, "Resolve all P0/P1 and mandatory-pause incidents before completion" if
          run.unresolved_incidents.any?(&:pause_required?)
        checkpoint = run.live_pilot_metric_snapshots.order(observed_at: :desc).first
        if checkpoint.nil? || checkpoint.pause_required? || checkpoint.observed_at < run.event.updated_at ||
            checkpoint.created_at < run.event.updated_at
          raise RunError, "A final post-event safe monitoring checkpoint is required"
        end
        current_local_metrics = ensure_current_checkpoint_safe!(run, checkpoint)
        ensure_local_closeout!(current_local_metrics)
        results = normalize_completion(attributes[:completion_results])
        validate_completion_results!(results)
        reference = attributes[:completion_evidence_reference].to_s.strip
        digest = attributes[:completion_evidence_digest].to_s.strip
        raise RunError, "A completion evidence reference is required" if reference.blank?
        raise RunError, "Completion evidence digest must be a lowercase SHA-256" unless digest.match?(/\A[0-9a-f]{64}\z/)

        run.update!(
          status: :completed, completed_by_user: actor, completed_at: Time.current,
          completion_evidence_reference: reference, completion_evidence_digest: digest,
          completion_results: results, paused_at: nil, pause_reason: nil
        )
        clear_gate_i_sales_suspension!(run.event)
        record_action!(run, :completed, actor, { evidence_reference: reference, results: results }, request)
      end
      run
    rescue ActiveRecord::RecordInvalid, ActiveRecord::StatementInvalid => e
      raise RunError, error_message(e)
    end

    def self.abort!(run:, actor:, reason:, request: nil)
      validate_admin!(actor)
      raise RunError, "A specific abort reason is required" if reason.to_s.strip.blank?
      run.event.with_lock do
        run.lock!
        unless run.status_active? || run.status_paused?
          raise RunError, "Only an open pilot run can be aborted"
        end
        now = Time.current
        run.update!(
          status: :aborted, aborted_at: now, abort_reason: reason.to_s.strip,
          paused_at: nil, pause_reason: nil
        )
        run.event.update!(sales_suspended_at: now, sales_suspension_reason: "[GATE I] #{reason.to_s.strip}")
        record_action!(run, :aborted, actor, { reason: reason.to_s.strip }, request)
      end
      run
    rescue ActiveRecord::RecordInvalid, ActiveRecord::StatementInvalid => e
      raise RunError, error_message(e)
    end

    def self.record_action!(run, kind, actor, details, request)
      action = run.live_pilot_run_actions.create!(
        event: run.event, actor_user: actor, kind: kind, details: details, occurred_at: Time.current
      )
      AuditLogger.record!(
        action: "live_pilot_run.#{kind}", auditable: action, actor: actor, organization: run.event.organization,
        after_data: action.attributes.slice("id", "live_pilot_run_id", "event_id", "kind", "details", "occurred_at"),
        request: request
      )
      action
    end

    def self.ensure_local_closeout!(metrics)
      required_zero = %w[
        pending_payment_count pending_refund_count active_hold_count open_reconciliation_exception_count
        unknown_card_payment_count unresolved_p0_p1_incident_count
      ]
      nonzero = required_zero.select { |field| metrics.to_h[field].to_i != 0 }
      raise RunError, "Final local operations are not reconciled: #{nonzero.join(', ')}" if nonzero.any?
    end
    private_class_method :ensure_local_closeout!

    def self.ensure_current_checkpoint_safe!(run, checkpoint)
      local = LivePilotMetrics::Manager.local_metrics(run)
      breaches = LivePilotMetrics::Manager.threshold_breaches(
        run.live_pilot_review.thresholds, local, checkpoint.external_metrics
      )
      if breaches.any?
        raise RunError, "Operations changed after the safe checkpoint: #{breaches.keys.join(', ')}"
      end

      local
    end
    private_class_method :ensure_current_checkpoint_safe!

    def self.clear_gate_i_sales_suspension!(event)
      return unless event.sales_suspension_reason.to_s.start_with?("[GATE I]")

      event.update!(sales_suspended_at: nil, sales_suspension_reason: nil)
    end
    private_class_method :clear_gate_i_sales_suspension!

    def self.normalize_completion(value)
      result = value.respond_to?(:to_h) ? value.to_h.stringify_keys : {}
      COMPLETION_BOOLEAN_FIELDS.each do |field|
        result[field] = ActiveModel::Type::Boolean.new.cast(result[field])
      end
      COMPLETION_ZERO_FIELDS.each do |field|
        result[field] = Integer(result[field], exception: false) || result[field]
      end
      result.slice(*(COMPLETION_BOOLEAN_FIELDS + COMPLETION_ZERO_FIELDS))
    end
    private_class_method :normalize_completion

    def self.validate_completion_results!(results)
      missing = COMPLETION_BOOLEAN_FIELDS.reject { |field| results[field] == true }
      raise RunError, "Completion must affirm: #{missing.join(', ')}" if missing.any?
      invalid = COMPLETION_ZERO_FIELDS.reject { |field| results[field] == 0 }
      raise RunError, "Completion variances and exceptions must be zero: #{invalid.join(', ')}" if invalid.any?
    end
    private_class_method :validate_completion_results!

    def self.validate_admin!(actor)
      raise RunError, "Only an administrator can manage a Gate I pilot run" unless actor&.admin?
    end
    private_class_method :validate_admin!

    def self.error_message(error)
      return error.record.errors.full_messages.to_sentence if error.respond_to?(:record)

      error.message.presence || "The live-pilot state conflicts with another operation"
    end
    private_class_method :error_message
  end
end
