# frozen_string_literal: true

module LivePilotReviews
  class Manager
    class ReviewError < StandardError; end

    SNAPSHOT_FIELDS = %i[
      event_day_rehearsal_review_id live_money_proof_review_id evidence_reference evidence_digest
      event_state_digest application_revision inventory_cap support_coverage assignments thresholds controls
      effective_at expires_at
    ].freeze

    def self.submit!(event:, attributes:, actor:, request: nil)
      validate_admin!(actor)
      review = nil
      event.with_lock do
        raise ReviewError, "The Gate H proof candidate cannot be used as a live pilot" if event.live_money_proof_candidate?
        prerequisites = current_prerequisites(event)
        raise ReviewError, "Current Gate G and applicable Gate H approvals are required first" unless prerequisites
        raise ReviewError, "Revoke the current Gate I approval before submitting another" if LivePilot.active_approval(event)
        raise ReviewError, "Decide the current Gate I submission before submitting another" if LivePilot.pending_submission(event)

        snapshot = normalize_snapshot(attributes.to_h.symbolize_keys.slice(*SNAPSHOT_FIELDS))
        snapshot.merge!(
          event_day_rehearsal_review_id: prerequisites[:rehearsal].id,
          live_money_proof_review_id: prerequisites[:live_money]&.id,
          event_state_digest: prerequisites[:state_digest],
          application_revision: PilotReadiness.application_revision
        )
        review = event.live_pilot_reviews.create!(snapshot.merge(decision: :submission, actor_user: actor))
        record!(review, "live_pilot.submitted", actor, request)
      end
      review
    rescue ActiveRecord::RecordInvalid, ActiveRecord::StatementInvalid => e
      raise ReviewError, error_message(e)
    end

    def self.approve!(submission:, actor:, request: nil)
      validate_admin!(actor)
      review = nil
      submission.event.with_lock do
        submission.reload
        validate_open_submission!(submission, actor: actor, approving: true)
        raise ReviewError, "The pilot authorization window is not yet effective" if submission.effective_at > Time.current
        raise ReviewError, "The pilot authorization window has expired" if submission.expires_at <= Time.current
        prerequisites = current_prerequisites(submission.event)
        unless prerequisites && snapshot_current?(submission, prerequisites)
          raise ReviewError, "Gate G, Gate H, application, or event configuration changed; submit a new pilot plan"
        end
        raise ReviewError, "Revoke the current Gate I approval before approving another" if
          LivePilot.active_approval(submission.event)

        review = submission.event.live_pilot_reviews.create!(snapshot(submission).merge(
          decision: :approval, parent_review: submission, actor_user: actor
        ))
        record!(review, "live_pilot.approved", actor, request)
      end
      review
    rescue ActiveRecord::RecordInvalid, ActiveRecord::RecordNotUnique, ActiveRecord::StatementInvalid => e
      raise ReviewError, error_message(e)
    end

    def self.reject!(submission:, actor:, reason:, request: nil)
      validate_admin!(actor)
      decide_negative!(submission, actor: actor, reason: reason, decision: :rejection,
        action: "live_pilot.rejected", request: request)
    end

    def self.revoke!(approval:, actor:, reason:, request: nil)
      validate_admin!(actor)
      raise ReviewError, "A specific revocation reason is required" if reason.to_s.strip.blank?
      review = nil
      approval.event.with_lock do
        approval.reload
        raise ReviewError, "Only an approval can be revoked" unless approval.decision_approval?
        raise ReviewError, "This approval has already been revoked" if approval.revoked?
        if approval.live_pilot_run&.status_active?
          raise ReviewError, "Pause or abort the active pilot run before revoking its approval"
        end
        review = approval.event.live_pilot_reviews.create!(snapshot(approval).merge(
          decision: :revocation, parent_review: approval, actor_user: actor, reason: reason.to_s.strip
        ))
        record!(review, "live_pilot.revoked", actor, request)
      end
      review
    rescue ActiveRecord::RecordInvalid, ActiveRecord::RecordNotUnique, ActiveRecord::StatementInvalid => e
      raise ReviewError, error_message(e)
    end

    def self.decide_negative!(submission, actor:, reason:, decision:, action:, request:)
      raise ReviewError, "A specific rejection reason is required" if reason.to_s.strip.blank?
      review = nil
      submission.event.with_lock do
        submission.reload
        validate_open_submission!(submission, actor: actor)
        review = submission.event.live_pilot_reviews.create!(snapshot(submission).merge(
          decision: decision, parent_review: submission, actor_user: actor, reason: reason.to_s.strip
        ))
        record!(review, action, actor, request)
      end
      review
    rescue ActiveRecord::RecordInvalid, ActiveRecord::RecordNotUnique, ActiveRecord::StatementInvalid => e
      raise ReviewError, error_message(e)
    end
    private_class_method :decide_negative!

    def self.current_prerequisites(event)
      state_digest = PilotReadiness.event_state_digest(event)
      rehearsal = EventDayRehearsal.active_approval(event, state_digest: state_digest)
      return unless rehearsal

      live_money = LiveMoneyProof.active_approval(event.organization) if LivePilot.paid_event?(event)
      return if LivePilot.paid_event?(event) && live_money.nil?

      { state_digest: state_digest, rehearsal: rehearsal, live_money: live_money }
    end
    private_class_method :current_prerequisites

    def self.snapshot_current?(review, prerequisites)
      review.event_state_digest == prerequisites[:state_digest] &&
        review.application_revision == PilotReadiness.application_revision &&
        review.event_day_rehearsal_review_id == prerequisites[:rehearsal].id &&
        review.live_money_proof_review_id == prerequisites[:live_money]&.id
    end
    private_class_method :snapshot_current?

    def self.validate_open_submission!(submission, actor:, approving: false)
      raise ReviewError, "Only a submission can be decided" unless submission.decision_submission?
      raise ReviewError, "This pilot-plan submission already has a decision" if
        submission.child_reviews.where(decision: [:approval, :rejection]).exists?
      if approving && submission.actor_user_id == actor.id
        raise ReviewError, "The submitter cannot approve their own pilot plan"
      end
    end
    private_class_method :validate_open_submission!

    def self.validate_admin!(actor)
      raise ReviewError, "Only an administrator can manage Gate I plans" unless actor&.admin?
    end
    private_class_method :validate_admin!

    def self.snapshot(review)
      review.attributes.symbolize_keys.slice(*SNAPSHOT_FIELDS)
    end
    private_class_method :snapshot

    def self.normalize_snapshot(snapshot)
      snapshot[:inventory_cap] = Integer(snapshot[:inventory_cap], exception: false) || snapshot[:inventory_cap]
      snapshot[:support_coverage] = normalize_nested(
        snapshot[:support_coverage], LivePilotReview::SUPPORT_WINDOWS, LivePilotReview::SUPPORT_FIELDS
      )
      snapshot[:assignments] = normalize_nested(
        snapshot[:assignments], LivePilotReview::ASSIGNMENT_KEYS, LivePilotReview::ASSIGNMENT_FIELDS
      )
      snapshot[:thresholds] = safe_hash(snapshot[:thresholds]).slice(*LivePilotReview::THRESHOLD_FIELDS)
        .transform_values { |value| Integer(value, exception: false) || value }
      snapshot[:controls] = safe_hash(snapshot[:controls]).slice(*LivePilotReview::CONTROL_KEYS)
        .transform_values { |value| ActiveModel::Type::Boolean.new.cast(value) }
      snapshot
    end
    private_class_method :normalize_snapshot

    def self.normalize_nested(value, keys, fields)
      safe_hash(value).slice(*keys).transform_values { |item| safe_hash(item).slice(*fields) }
    end
    private_class_method :normalize_nested

    def self.safe_hash(value)
      value.respond_to?(:to_h) ? value.to_h.stringify_keys : {}
    end
    private_class_method :safe_hash

    def self.record!(review, action, actor, request)
      assignment_summary = review.assignments.transform_values { |result| { "assigned" => result.to_h.present? } }
      coverage_summary = review.support_coverage.transform_values do |result|
        result.to_h.slice("starts_at", "ends_at").merge("configured" => result.to_h.present?)
      end
      AuditLogger.record!(
        action: action, auditable: review, actor: actor, organization: review.event.organization,
        after_data: review.attributes.slice(
          "id", "event_id", "event_day_rehearsal_review_id", "live_money_proof_review_id",
          "parent_review_id", "actor_user_id", "decision", "evidence_reference", "evidence_digest",
          "event_state_digest", "application_revision", "inventory_cap", "thresholds", "controls",
          "effective_at", "expires_at", "reason"
        ).merge("support_coverage" => coverage_summary, "assignments" => assignment_summary),
        request: request
      )
    end
    private_class_method :record!

    def self.error_message(error)
      return error.record.errors.full_messages.to_sentence if error.respond_to?(:record)

      error.message.presence || "Live-pilot evidence conflicts with an existing decision"
    end
    private_class_method :error_message
  end
end
