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

    # One-time platform setup an admin approves with a single click from the
    # admin dashboard: every control is affirmed by that admin, and the audit
    # log records the submission and approval under their name.
    QUICK_APPROVAL_CAPABILITIES = %w[policy_register resend_production].freeze
    QUICK_APPROVAL_TERM = 1.year

    # While policies are drafts, the policy register needs the same explicit
    # draft-launch acknowledgment as the full review; it is recorded on the
    # approval and in the audit log. The check, submission and approval run
    # under one settings-row lock, so two clicks cannot approve twice.
    def self.quick_approve!(capability:, actor:, request: nil, draft_policies_acknowledged: false)
      capability = capability.to_s
      raise ReviewError, "This capability needs a full evidence review" unless QUICK_APPROVAL_CAPABILITIES.include?(capability)
      raise ReviewError, "Administrator access is required" unless actor&.admin?

      SiteSetting.transaction do
        SiteSetting.instance.lock!
        raise ReviewError, "Already approved" if PlatformCapabilities.active_approval(capability)

        now = Time.current
        reference = "admin-dashboard/#{capability}/#{now.utc.iso8601}"
        submission = submit!(capability: capability, actor: actor, request: request, attributes: {
          evidence_reference: reference,
          evidence_digest: Digest::SHA256.hexdigest(JSON.generate([reference, actor.id,
            PlatformCapabilities.configuration_digest(capability)])),
          controls: PlatformCapabilities.required_controls(capability).index_with(true),
          effective_at: now - 1.second, expires_at: now + QUICK_APPROVAL_TERM
        })
        approve!(submission: submission, actor: actor, request: request,
          draft_policies_acknowledged: draft_policies_acknowledged)
      end
    end

    def self.approve!(submission:, actor:, request: nil, draft_policies_acknowledged: false)
      review = nil
      SiteSetting.instance.with_lock do
        submission.reload
        validate_open_submission!(submission)
        raise ReviewError, "The evidence approval window is not yet effective" if submission.effective_at > Time.current
        raise ReviewError, "The evidence approval window has expired" if submission.expires_at <= Time.current
        unless submission.configuration_digest == PlatformCapabilities.configuration_digest(submission.capability)
          raise ReviewError, "Provider or policy configuration changed; submit a new evidence snapshot"
        end
        if PlatformCapabilities.active_approval(submission.capability)
          raise ReviewError, "Revoke the current approval before approving another"
        end
        acknowledgment = nil
        if submission.capability == "policy_register"
          blockers = PolicyRegistry.approval_blockers
          raise ReviewError, "Policy text has technical problems: #{blockers.join('; ')}" if blockers.any?
          # Launching on draft policies is the operator's call, made explicitly
          # and recorded on the approval and in the audit log.
          if PolicyRegistry.draft?
            unless draft_policies_acknowledged
              raise ReviewError, "Confirm that you are approving draft policies for launch before legal review"
            end
            acknowledgment = PolicyRegistry::DRAFT_ACKNOWLEDGMENT
          end
        end

        review = PlatformCapabilityReview.create!(snapshot(submission).merge(
          decision: :approval, parent_review: submission, actor_user: actor, reason: acknowledgment
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
        validate_open_submission!(submission)
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

    def self.validate_open_submission!(submission)
      raise ReviewError, "Only a submission can be decided" unless submission.decision_submission?
      if submission.child_reviews.where(decision: [:approval, :rejection]).exists?
        raise ReviewError, "This submission already has a decision"
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
        metadata: review.decision_approval? && review.reason == PolicyRegistry::DRAFT_ACKNOWLEDGMENT ?
          { "draft_policies_acknowledged" => true, "policy_version" => PolicyRegistry.version } : {},
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
