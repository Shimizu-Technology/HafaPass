# frozen_string_literal: true

module PlatformCapabilityReviews
  class Manager
    class ReviewError < StandardError; end

    SNAPSHOT_FIELDS = %i[capability evidence_reference evidence_digest configuration_digest controls effective_at expires_at].freeze

    def self.submit!(capability:, attributes:, actor:, request: nil)
      capability = capability.to_s
      raise ReviewError, "Capability configuration is incomplete" unless PlatformCapabilities.configured?(capability)

      snapshot = attributes.to_h.symbolize_keys.slice(*SNAPSHOT_FIELDS)
      snapshot[:capability] = capability
      snapshot[:configuration_digest] = PlatformCapabilities.configuration_digest(capability)
      snapshot[:controls] = snapshot.fetch(:controls, {}).to_h.transform_values do |value|
        ActiveModel::Type::Boolean.new.cast(value)
      end
      review = nil
      SiteSetting.instance.with_lock do
        review = PlatformCapabilityReview.create!(snapshot.merge(decision: :submission, actor_user: actor))
        record!(review, "platform_capability.submitted", actor, request)
      end
      review
    rescue ArgumentError, ActiveRecord::RecordInvalid, ActiveRecord::StatementInvalid => e
      raise ReviewError, error_message(e)
    end

    def self.approve!(submission:, actor:, request: nil)
      review = nil
      SiteSetting.instance.with_lock do
        submission.reload
        validate_open_submission!(submission, actor: actor, approving: true)
        raise ReviewError, "The evidence approval window is not yet effective" if submission.effective_at > Time.current
        raise ReviewError, "The evidence approval window has expired" if submission.expires_at <= Time.current
        unless submission.configuration_digest == PlatformCapabilities.configuration_digest(submission.capability)
          raise ReviewError, "Provider or policy configuration changed; submit a new evidence snapshot"
        end
        if PlatformCapabilities.active_approval(submission.capability)
          raise ReviewError, "Revoke the current approval before approving another"
        end

        review = PlatformCapabilityReview.create!(snapshot(submission).merge(
          decision: :approval, parent_review: submission, actor_user: actor
        ))
        record!(review, "platform_capability.approved", actor, request)
      end
      review
    rescue ActiveRecord::RecordInvalid, ActiveRecord::RecordNotUnique, ActiveRecord::StatementInvalid => e
      raise ReviewError, error_message(e)
    end

    def self.reject!(submission:, actor:, reason:, request: nil)
      raise ReviewError, "A specific rejection reason is required" if reason.to_s.strip.blank?
      review = nil
      SiteSetting.instance.with_lock do
        submission.reload
        validate_open_submission!(submission, actor: actor)
        review = PlatformCapabilityReview.create!(snapshot(submission).merge(
          decision: :rejection, parent_review: submission, actor_user: actor, reason: reason.to_s.strip
        ))
        record!(review, "platform_capability.rejected", actor, request)
      end
      review
    rescue ActiveRecord::RecordInvalid, ActiveRecord::RecordNotUnique, ActiveRecord::StatementInvalid => e
      raise ReviewError, error_message(e)
    end

    def self.revoke!(approval:, actor:, reason:, request: nil)
      raise ReviewError, "A specific revocation reason is required" if reason.to_s.strip.blank?
      review = nil
      SiteSetting.instance.with_lock do
        approval.reload
        raise ReviewError, "Only an approval can be revoked" unless approval.decision_approval?
        raise ReviewError, "This approval has already been revoked" if approval.revoked?
        review = PlatformCapabilityReview.create!(snapshot(approval).merge(
          decision: :revocation, parent_review: approval, actor_user: actor, reason: reason.to_s.strip
        ))
        record!(review, "platform_capability.revoked", actor, request)
      end
      review
    rescue ActiveRecord::RecordInvalid, ActiveRecord::RecordNotUnique, ActiveRecord::StatementInvalid => e
      raise ReviewError, error_message(e)
    end

    def self.validate_open_submission!(submission, actor:, approving: false)
      raise ReviewError, "Only a submission can be decided" unless submission.decision_submission?
      if submission.child_reviews.where(decision: [:approval, :rejection]).exists?
        raise ReviewError, "This submission already has a decision"
      end
      if approving && submission.actor_user_id == actor.id
        raise ReviewError, "The submitter cannot approve their own evidence"
      end
    end
    private_class_method :validate_open_submission!

    def self.snapshot(review)
      review.attributes.symbolize_keys.slice(*SNAPSHOT_FIELDS)
    end
    private_class_method :snapshot

    def self.record!(review, action, actor, request)
      AuditLogger.record!(
        action: action,
        auditable: review,
        actor: actor,
        after_data: review.attributes.slice(
          "id", "parent_review_id", "actor_user_id", "capability", "decision", "evidence_reference",
          "evidence_digest", "configuration_digest", "controls", "effective_at", "expires_at", "reason"
        ),
        request: request
      )
    end
    private_class_method :record!

    def self.error_message(error)
      return error.record.errors.full_messages.to_sentence if error.respond_to?(:record)

      error.message.presence || "Platform capability evidence conflicts with an existing decision"
    end
    private_class_method :error_message
  end
end
