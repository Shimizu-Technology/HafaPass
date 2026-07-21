# frozen_string_literal: true

module PilotCloseoutReviews
  class Manager
    class ReviewError < StandardError; end

    def self.submit!(run:, attributes:, actor:, request: nil)
      validate_admin!(actor)
      review = nil
      run.event.with_lock do
        run.lock!
        raise ReviewError, "Gate J requires a completed Gate I run" unless run.status_completed?
        raise ReviewError, "Decide the current Gate J submission before submitting another" if
          PilotCloseout.pending_submission(run)
        raise ReviewError, "Revoke the current Gate J approval before submitting another" if
          PilotCloseout.active_approval(run)

        local_metrics = PilotCloseout.local_metrics(run)
        PilotCloseout.ensure_closeout_ready!(run, local_metrics)
        snapshot = normalize_snapshot(attributes)
        snapshot.merge!(
          event: run.event, live_pilot_run: run, decision: :submission, actor_user: actor,
          local_metrics: local_metrics, local_state_digest: PilotCloseout.local_state_digest(run, local_metrics),
          application_revision: PilotReadiness.application_revision, signed_at: Time.current
        )
        review = PilotCloseoutReview.create!(snapshot)
        audit!(review, "pilot_closeout.submitted", actor, request)
      end
      review
    rescue PilotCloseout::StateError => e
      raise ReviewError, e.message
    rescue ActiveRecord::RecordInvalid, ActiveRecord::StatementInvalid => e
      raise ReviewError, error_message(e)
    end

    def self.approve!(submission:, actor:, request: nil)
      validate_admin!(actor)
      review = nil
      submission.event.with_lock do
        submission.reload
        submission.live_pilot_run.lock!
        validate_open_submission!(submission, actor: actor, approving: true)
        current_metrics = PilotCloseout.local_metrics(submission.live_pilot_run)
        PilotCloseout.ensure_closeout_ready!(submission.live_pilot_run, current_metrics)
        current_digest = PilotCloseout.local_state_digest(submission.live_pilot_run, current_metrics)
        unless submission.local_state_digest == current_digest && submission.local_metrics == current_metrics &&
            submission.application_revision == PilotReadiness.application_revision
          raise ReviewError, "Local operations or the application changed; submit a new Gate J closeout"
        end
        if !submission.expansion_decision_hold? && unresolved_expansion_blockers(submission).any?
          raise ReviewError, "Complete every expansion-blocking retrospective action before approving expansion"
        end

        review = PilotCloseoutReview.create!(snapshot(submission).merge(
          decision: :approval, parent_review: submission, actor_user: actor, signed_at: Time.current
        ))
        audit!(review, "pilot_closeout.approved", actor, request)
      end
      review
    rescue PilotCloseout::StateError => e
      raise ReviewError, e.message
    rescue ActiveRecord::RecordInvalid, ActiveRecord::RecordNotUnique, ActiveRecord::StatementInvalid => e
      raise ReviewError, error_message(e)
    end

    def self.reject!(submission:, actor:, reason:, request: nil)
      decide_negative!(submission, actor: actor, reason: reason, decision: :rejection,
        action: "pilot_closeout.rejected", request: request)
    end

    def self.revoke!(approval:, actor:, reason:, request: nil)
      validate_admin!(actor)
      raise ReviewError, "A specific revocation reason is required" if reason.to_s.strip.blank?
      review = nil
      approval.event.with_lock do
        approval.reload
        raise ReviewError, "Only an approval can be revoked" unless approval.decision_approval?
        raise ReviewError, "This Gate J approval has already been revoked" if approval.revoked?

        review = PilotCloseoutReview.create!(snapshot(approval).merge(
          decision: :revocation, parent_review: approval, actor_user: actor,
          signed_at: Time.current, reason: reason.to_s.strip
        ))
        audit!(review, "pilot_closeout.revoked", actor, request)
      end
      review
    rescue ActiveRecord::RecordInvalid, ActiveRecord::RecordNotUnique, ActiveRecord::StatementInvalid => e
      raise ReviewError, error_message(e)
    end

    def self.normalize_snapshot(attributes)
      values = attributes.respond_to?(:to_h) ? attributes.to_h.stringify_keys : {}
      {
        evidence_reference: values["evidence_reference"].to_s.strip,
        evidence_digest: values["evidence_digest"].to_s.strip.downcase,
        expansion_decision: values["expansion_decision"],
        outcome_metrics: normalize_outcomes(values["outcome_metrics"]),
        reconciliation_results: normalize_booleans(
          values["reconciliation_results"], PilotCloseoutReview::RECONCILIATION_FIELDS
        ),
        cleanup_results: normalize_booleans(values["cleanup_results"], PilotCloseoutReview::CLEANUP_FIELDS),
        evidence_references: normalize_strings(
          values["evidence_references"], PilotCloseoutReview::EVIDENCE_REFERENCE_FIELDS
        ),
        retrospective_actions: normalize_actions(values["retrospective_actions"]),
        expansion_scope: normalize_expansion_scope(values["expansion_scope"])
      }
    end
    private_class_method :normalize_snapshot

    def self.normalize_outcomes(value)
      values = safe_hash(value).slice(*PilotCloseoutReview::OUTCOME_INTEGER_FIELDS)
      values.transform_values { |item| Integer(item, exception: false) || item }
    end
    private_class_method :normalize_outcomes

    def self.normalize_booleans(value, fields)
      safe_hash(value).slice(*fields).transform_values { |item| strict_boolean(item) }
    end
    private_class_method :normalize_booleans

    def self.normalize_strings(value, fields)
      safe_hash(value).slice(*fields).transform_values { |item| item.to_s.strip }
    end
    private_class_method :normalize_strings

    def self.normalize_actions(value)
      Array(value).first(25).map do |raw|
        action = safe_hash(raw).slice(
          "title", "owner_reference", "due_at", "status", "priority", "evidence_reference", "blocks_expansion"
        )
        action.transform_values! { |item| item.is_a?(String) ? item.strip : item }
        action["blocks_expansion"] = strict_boolean(action["blocks_expansion"])
        action
      end
    end
    private_class_method :normalize_actions

    def self.normalize_expansion_scope(value)
      scope = safe_hash(value).slice(
        "event_limit", "max_inventory_per_event", "expires_at", "new_regions",
        "recommended_product_investments", "product_evidence_reference", "demand_evidence_reference",
        "capacity_evidence_reference", "rationale"
      )
      %w[event_limit max_inventory_per_event].each do |field|
        scope[field] = Integer(scope[field], exception: false) || scope[field]
      end
      scope["new_regions"] = strict_boolean(scope["new_regions"])
      scope["recommended_product_investments"] = Array(scope["recommended_product_investments"])
        .map { |item| item.to_s.strip }.reject(&:blank?).uniq
      %w[
        expires_at product_evidence_reference demand_evidence_reference capacity_evidence_reference rationale
      ].each { |field| scope[field] = scope[field].to_s.strip.presence }
      scope
    end
    private_class_method :normalize_expansion_scope

    def self.snapshot(review)
      review.attributes.symbolize_keys.slice(*PilotCloseoutReview::SNAPSHOT_FIELDS.map(&:to_sym))
    end
    private_class_method :snapshot

    def self.decide_negative!(submission, actor:, reason:, decision:, action:, request:)
      validate_admin!(actor)
      raise ReviewError, "A specific rejection reason is required" if reason.to_s.strip.blank?
      review = nil
      submission.event.with_lock do
        submission.reload
        validate_open_submission!(submission, actor: actor)
        review = PilotCloseoutReview.create!(snapshot(submission).merge(
          decision: decision, parent_review: submission, actor_user: actor,
          signed_at: Time.current, reason: reason.to_s.strip
        ))
        audit!(review, action, actor, request)
      end
      review
    rescue ActiveRecord::RecordInvalid, ActiveRecord::RecordNotUnique, ActiveRecord::StatementInvalid => e
      raise ReviewError, error_message(e)
    end
    private_class_method :decide_negative!

    def self.validate_open_submission!(submission, actor:, approving: false)
      raise ReviewError, "Only a Gate J submission can be decided" unless submission.decision_submission?
      if submission.child_reviews.where(decision: [:approval, :rejection]).exists?
        raise ReviewError, "This Gate J submission already has a decision"
      end
      if approving && submission.actor_user_id == actor.id
        raise ReviewError, "The closeout submitter cannot approve their own Gate J decision"
      end
    end
    private_class_method :validate_open_submission!

    def self.unresolved_expansion_blockers(review)
      review.retrospective_actions.select do |action|
        values = action.to_h.stringify_keys
        values["blocks_expansion"] == true && values["status"] != "completed"
      end
    end
    private_class_method :unresolved_expansion_blockers

    def self.safe_hash(value)
      value.respond_to?(:to_h) ? value.to_h.stringify_keys : {}
    end
    private_class_method :safe_hash

    def self.strict_boolean(value)
      return true if value == true || value == 1 || value == "1" || value == "true"
      return false if value == false || value == 0 || value == "0" || value == "false"

      value
    end
    private_class_method :strict_boolean

    def self.validate_admin!(actor)
      raise ReviewError, "Only an administrator can manage Gate J closeout" unless actor&.admin?
    end
    private_class_method :validate_admin!

    def self.audit!(review, action, actor, request)
      retrospective_summary = review.retrospective_actions.map do |item|
        values = item.to_h.stringify_keys
        values.slice("status", "priority", "blocks_expansion")
      end
      AuditLogger.record!(
        action: action, auditable: review, actor: actor, organization: review.event.organization,
        after_data: review.attributes.slice(
          "id", "event_id", "live_pilot_run_id", "parent_review_id", "actor_user_id", "decision",
          "expansion_decision", "evidence_reference", "evidence_digest", "local_state_digest",
          "application_revision", "local_metrics", "outcome_metrics", "reconciliation_results",
          "cleanup_results", "expansion_scope", "signed_at", "reason"
        ).merge("retrospective_actions" => retrospective_summary), request: request
      )
    end
    private_class_method :audit!

    def self.error_message(error)
      return error.record.errors.full_messages.to_sentence if error.respond_to?(:record)

      error.message.presence || "Gate J closeout evidence conflicts with an existing decision"
    end
    private_class_method :error_message
  end
end
