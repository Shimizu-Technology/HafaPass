# frozen_string_literal: true

module PilotValidationReviews
  class Manager
    class ReviewError < StandardError; end

    SNAPSHOT_FIELDS = %i[
      pilot_readiness_review_id evidence_reference evidence_digest event_state_digest application_revision
      device_matrix buyer_flows organizer_flows accessibility_results load_results controls effective_at expires_at
    ].freeze

    def self.submit!(event:, attributes:, actor:, request: nil)
      review = nil
      event.with_lock do
        readiness = PilotReadiness.active_approval(event)
        raise ReviewError, "A current Gate E pilot readiness approval is required first" unless readiness
        if PilotValidation.active_approval(event, readiness_approval: readiness)
          raise ReviewError, "Revoke the current Gate F validation approval before submitting another"
        end
        if PilotValidation.pending_submission(event)
          raise ReviewError, "Decide the current Gate F validation submission before submitting another"
        end

        snapshot = attributes.to_h.symbolize_keys.slice(*SNAPSHOT_FIELDS)
        snapshot[:device_matrix] = normalize_device_matrix(snapshot[:device_matrix])
        snapshot[:buyer_flows] = normalize_boolean_matrix(snapshot[:buyer_flows], PilotValidationReview::BUYER_FLOW_KEYS)
        snapshot[:organizer_flows] = normalize_boolean_matrix(
          snapshot[:organizer_flows], PilotValidationReview::ORGANIZER_FLOW_KEYS
        )
        snapshot[:accessibility_results] = normalize_accessibility(snapshot[:accessibility_results])
        snapshot[:load_results] = normalize_load_results(snapshot[:load_results])
        snapshot[:controls] = normalize_boolean_matrix(snapshot[:controls], PilotValidationReview::CONTROL_KEYS)
        snapshot[:pilot_readiness_review_id] = readiness.id
        snapshot[:event_state_digest] = readiness.event_state_digest
        snapshot[:application_revision] = PilotReadiness.application_revision
        review = event.pilot_validation_reviews.create!(snapshot.merge(decision: :submission, actor_user: actor))
        record!(review, "pilot_validation.submitted", actor, request)
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
        raise ReviewError, "The validation window is not yet effective" if submission.effective_at > Time.current
        raise ReviewError, "The validation window has expired" if submission.expires_at <= Time.current
        state_digest = PilotReadiness.event_state_digest(submission.event)
        readiness = PilotReadiness.active_approval(submission.event, state_digest: state_digest)
        unless readiness&.id == submission.pilot_readiness_review_id &&
            submission.event_state_digest == state_digest &&
            submission.application_revision == PilotReadiness.application_revision
          raise ReviewError, "Gate E, application, or event configuration changed; submit new validation evidence"
        end
        if PilotValidation.active_approval(submission.event, readiness_approval: readiness)
          raise ReviewError, "Revoke the current Gate F validation approval before approving another"
        end

        review = submission.event.pilot_validation_reviews.create!(snapshot(submission).merge(
          decision: :approval, parent_review: submission, actor_user: actor
        ))
        record!(review, "pilot_validation.approved", actor, request)
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
        review = submission.event.pilot_validation_reviews.create!(snapshot(submission).merge(
          decision: :rejection, parent_review: submission, actor_user: actor, reason: reason.to_s.strip
        ))
        record!(review, "pilot_validation.rejected", actor, request)
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
        review = approval.event.pilot_validation_reviews.create!(snapshot(approval).merge(
          decision: :revocation, parent_review: approval, actor_user: actor, reason: reason.to_s.strip
        ))
        record!(review, "pilot_validation.revoked", actor, request)
      end
      review
    rescue ActiveRecord::RecordInvalid, ActiveRecord::RecordNotUnique, ActiveRecord::StatementInvalid => e
      raise ReviewError, error_message(e)
    end

    def self.validate_open_submission!(submission, actor:, approving: false)
      raise ReviewError, "Only a submission can be decided" unless submission.decision_submission?
      if submission.child_reviews.where(decision: [:approval, :rejection]).exists?
        raise ReviewError, "This validation submission already has a decision"
      end
      if approving && submission.actor_user_id == actor.id
        raise ReviewError, "The submitter cannot approve their own validation evidence"
      end
    end
    private_class_method :validate_open_submission!

    def self.snapshot(review)
      review.attributes.symbolize_keys.slice(*SNAPSHOT_FIELDS)
    end
    private_class_method :snapshot

    def self.normalize_device_matrix(matrix)
      matrix.to_h.stringify_keys.slice(*PilotValidationReview::DEVICE_TARGETS.keys).transform_values do |result|
        normalized = result.to_h.stringify_keys.slice(*PilotValidationReview::DEVICE_FIELDS)
        if normalized.key?("physical_device")
          normalized["physical_device"] = ActiveModel::Type::Boolean.new.cast(normalized["physical_device"])
        end
        normalized
      end
    end
    private_class_method :normalize_device_matrix

    def self.normalize_boolean_matrix(matrix, keys)
      matrix.to_h.stringify_keys.slice(*keys).transform_values do |value|
        ActiveModel::Type::Boolean.new.cast(value)
      end
    end
    private_class_method :normalize_boolean_matrix

    def self.normalize_accessibility(results)
      normalized = results.to_h.stringify_keys
      {
        "checks" => normalize_boolean_matrix(
          normalized["checks"], PilotValidationReview::ACCESSIBILITY_CHECK_KEYS
        ),
        "assistive_technology" => normalized["assistive_technology"].to_h.stringify_keys
          .slice(*PilotValidationReview::ASSISTIVE_TECHNOLOGY_TARGETS).transform_values do |result|
            result.to_h.stringify_keys.slice(*PilotValidationReview::ASSISTIVE_TECHNOLOGY_FIELDS)
          end,
        "reviewer" => normalized["reviewer"].to_h.stringify_keys
          .slice(*PilotValidationReview::ACCESSIBILITY_REVIEWER_FIELDS)
      }
    end
    private_class_method :normalize_accessibility

    def self.normalize_load_results(results)
      normalized = results.to_h.stringify_keys.slice(*PilotValidationReview::LOAD_RESULT_FIELDS)
      if normalized.key?("all_holds_reconciled")
        normalized["all_holds_reconciled"] = ActiveModel::Type::Boolean.new.cast(normalized["all_holds_reconciled"])
      end
      normalized
    end
    private_class_method :normalize_load_results

    def self.record!(review, action, actor, request)
      device_summary = review.device_matrix.to_h.transform_values do |result|
        result.to_h.slice("status", "device_name", "os_version", "browser_version", "physical_device")
      end
      assistive_summary = review.accessibility_results.to_h.fetch("assistive_technology", {}).transform_values do |result|
        result.to_h.slice("status", "platform", "technology_version")
      end
      AuditLogger.record!(
        action: action,
        auditable: review,
        actor: actor,
        organization: review.event.organization,
        after_data: review.attributes.slice(
          "id", "event_id", "pilot_readiness_review_id", "parent_review_id", "actor_user_id", "decision",
          "evidence_reference", "evidence_digest", "event_state_digest", "application_revision", "buyer_flows",
          "organizer_flows", "load_results", "controls", "effective_at", "expires_at", "reason"
        ).merge("device_matrix" => device_summary, "assistive_technology" => assistive_summary),
        request: request
      )
    end
    private_class_method :record!

    def self.error_message(error)
      return error.record.errors.full_messages.to_sentence if error.respond_to?(:record)

      error.message.presence || "Pilot validation evidence conflicts with an existing decision"
    end
    private_class_method :error_message
  end
end
