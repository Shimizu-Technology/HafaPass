# frozen_string_literal: true

module PilotReadinessReviews
  class Manager
    class ReviewError < StandardError; end

    SNAPSHOT_FIELDS = %i[
      evidence_reference evidence_digest event_state_digest controls assignments effective_at expires_at
    ].freeze

    def self.submit!(event:, attributes:, actor:, request: nil)
      snapshot = attributes.to_h.symbolize_keys.slice(*SNAPSHOT_FIELDS)
      snapshot[:controls] = normalize_controls(snapshot[:controls])
      snapshot[:assignments] = normalize_assignments(snapshot[:assignments])
      review = nil

      event.with_lock do
        incomplete = event.publish_checklist.reject do |item|
          item[:complete] || item[:code] == "pilot_readiness_approved"
        end
        if incomplete.any?
          raise ReviewError, "Complete event configuration first: #{incomplete.map { |item| item[:label] }.join(', ')}"
        end
        if PilotReadiness.active_approval(event)
          raise ReviewError, "Revoke the current pilot readiness approval before submitting another"
        end

        snapshot[:event_state_digest] = PilotReadiness.event_state_digest(event)
        review = event.pilot_readiness_reviews.create!(snapshot.merge(decision: :submission, actor_user: actor))
        record!(review, "pilot_readiness.submitted", actor, request)
      end
      review
    rescue ActiveRecord::RecordInvalid, ActiveRecord::StatementInvalid => e
      raise ReviewError, error_message(e)
    end

    def self.approve!(submission:, actor:, request: nil)
      review = nil
      submission.event.with_lock do
        submission.reload
        validate_open_submission!(submission, actor: actor, approving: true)
        raise ReviewError, "The readiness window is not yet effective" if submission.effective_at > Time.current
        raise ReviewError, "The readiness window has expired" if submission.expires_at <= Time.current
        unless submission.event_state_digest == PilotReadiness.event_state_digest(submission.event)
          raise ReviewError, "Event or organizer configuration changed; submit a new readiness snapshot"
        end
        if PilotReadiness.active_approval(submission.event)
          raise ReviewError, "Revoke the current pilot readiness approval before approving another"
        end

        review = submission.event.pilot_readiness_reviews.create!(snapshot(submission).merge(
          decision: :approval, parent_review: submission, actor_user: actor
        ))
        record!(review, "pilot_readiness.approved", actor, request)
      end
      review
    rescue ActiveRecord::RecordInvalid, ActiveRecord::RecordNotUnique, ActiveRecord::StatementInvalid => e
      raise ReviewError, error_message(e)
    end

    def self.reject!(submission:, actor:, reason:, request: nil)
      raise ReviewError, "A specific rejection reason is required" if reason.to_s.strip.blank?
      review = nil
      submission.event.with_lock do
        submission.reload
        validate_open_submission!(submission, actor: actor)
        review = submission.event.pilot_readiness_reviews.create!(snapshot(submission).merge(
          decision: :rejection, parent_review: submission, actor_user: actor, reason: reason.to_s.strip
        ))
        record!(review, "pilot_readiness.rejected", actor, request)
      end
      review
    rescue ActiveRecord::RecordInvalid, ActiveRecord::RecordNotUnique, ActiveRecord::StatementInvalid => e
      raise ReviewError, error_message(e)
    end

    def self.revoke!(approval:, actor:, reason:, request: nil)
      raise ReviewError, "A specific revocation reason is required" if reason.to_s.strip.blank?
      review = nil
      approval.event.with_lock do
        approval.reload
        raise ReviewError, "Only an approval can be revoked" unless approval.decision_approval?
        raise ReviewError, "This approval has already been revoked" if approval.revoked?
        review = approval.event.pilot_readiness_reviews.create!(snapshot(approval).merge(
          decision: :revocation, parent_review: approval, actor_user: actor, reason: reason.to_s.strip
        ))
        record!(review, "pilot_readiness.revoked", actor, request)
      end
      review
    rescue ActiveRecord::RecordInvalid, ActiveRecord::RecordNotUnique, ActiveRecord::StatementInvalid => e
      raise ReviewError, error_message(e)
    end

    def self.validate_open_submission!(submission, actor:, approving: false)
      raise ReviewError, "Only a submission can be decided" unless submission.decision_submission?
      if submission.child_reviews.where(decision: [:approval, :rejection]).exists?
        raise ReviewError, "This readiness submission already has a decision"
      end
      if approving && submission.actor_user_id == actor.id
        raise ReviewError, "The submitter cannot approve their own readiness evidence"
      end
    end
    private_class_method :validate_open_submission!

    def self.normalize_controls(controls)
      controls.to_h.stringify_keys.slice(*PilotReadinessReview::CONTROL_KEYS).transform_values do |value|
        ActiveModel::Type::Boolean.new.cast(value)
      end
    end
    private_class_method :normalize_controls

    def self.normalize_assignments(assignments)
      assignments.to_h.stringify_keys.slice(*PilotReadinessReview::ASSIGNMENT_KEYS).transform_values do |assignment|
        assignment.to_h.stringify_keys.slice(*PilotReadinessReview::ASSIGNMENT_FIELDS).transform_values do |value|
          value.to_s.strip
        end
      end
    end
    private_class_method :normalize_assignments

    def self.snapshot(review)
      review.attributes.symbolize_keys.slice(*SNAPSHOT_FIELDS)
    end
    private_class_method :snapshot

    def self.record!(review, action, actor, request)
      AuditLogger.record!(
        action: action,
        auditable: review,
        actor: actor,
        organization: review.event.organization,
        after_data: review.attributes.slice(
          "id", "event_id", "parent_review_id", "actor_user_id", "decision", "evidence_reference",
          "evidence_digest", "event_state_digest", "controls", "effective_at", "expires_at", "reason"
        ).merge("assignment_roles" => review.assignments.keys.sort),
        request: request
      )
    end
    private_class_method :record!

    def self.error_message(error)
      return error.record.errors.full_messages.to_sentence if error.respond_to?(:record)

      error.message.presence || "Pilot readiness evidence conflicts with an existing decision"
    end
    private_class_method :error_message
  end
end
