# frozen_string_literal: true

module PaymentReadinessReviews
  class Manager
    class ReviewError < StandardError; end

    SNAPSHOT_FIELDS = %i[
      evidence_reference evidence_digest provider_approval_reference merchant_of_record
      fee_tax_schedule_reference liability_schedule_reference controls effective_at expires_at
      provider_state_digest
    ].freeze

    def self.submit!(account:, attributes:, actor:, request: nil)
      snapshot = attributes.to_h.symbolize_keys.slice(*SNAPSHOT_FIELDS)
      snapshot[:controls] = snapshot.fetch(:controls, {}).to_h.transform_values do |value|
        ActiveModel::Type::Boolean.new.cast(value)
      end
      review = nil
      account.with_lock do
        raise ReviewError, "Provider capabilities and onboarding must be complete first" unless account.externally_ready?
        snapshot[:provider_state_digest] = account.readiness_state_digest

        review = account.payment_readiness_reviews.create!(
          snapshot.merge(
            decision: :submission,
            actor_user: actor
          )
        )
        record!(review, "payment_readiness.submitted", actor, request)
      end
      review
    rescue ActiveRecord::RecordInvalid, ActiveRecord::StatementInvalid => e
      raise ReviewError, error_message(e)
    end

    def self.approve!(submission:, actor:, request: nil)
      raise ReviewError, "Only a submission can be approved" unless submission.decision_submission?
      raise ReviewError, "The submitter cannot approve their own evidence" if submission.actor_user_id == actor.id
      if submission.child_reviews.where(decision: [:approval, :rejection]).exists?
        raise ReviewError, "This submission already has a decision"
      end
      raise ReviewError, "The evidence approval window has expired" if submission.expires_at <= Time.current
      review = nil
      submission.connected_account.with_lock do
        if submission.reload.child_reviews.where(decision: [:approval, :rejection]).exists?
          raise ReviewError, "This submission already has a decision"
        end
        raise ReviewError, "The evidence approval window has expired" if submission.expires_at <= Time.current
        unless submission.provider_state_digest == submission.connected_account.readiness_state_digest
          raise ReviewError, "Provider state changed; submit a new evidence snapshot"
        end
        if submission.connected_account.active_payment_readiness_approval
          raise ReviewError, "Revoke the current readiness approval before approving another"
        end
        review = submission.connected_account.payment_readiness_reviews.create!(
          snapshot(submission).merge(
            decision: :approval,
            parent_review: submission,
            actor_user: actor
          )
        )
        ConnectedAccounts::Manager.refresh_readiness!(
          account: submission.connected_account,
          actor: actor,
          request: request,
          action: "connected_account.readiness_approved"
        )
        record!(review, "payment_readiness.approved", actor, request)
      end
      review
    rescue ActiveRecord::RecordInvalid, ActiveRecord::RecordNotUnique, ActiveRecord::StatementInvalid,
      ConnectedAccounts::Manager::AccountError => e
      raise ReviewError, error_message(e)
    end

    def self.revoke!(approval:, actor:, reason:, request: nil)
      raise ReviewError, "Only an approval can be revoked" unless approval.decision_approval?
      raise ReviewError, "This approval has already been revoked" if approval.revoked?
      raise ReviewError, "A specific revocation reason is required" if reason.to_s.strip.blank?

      review = nil
      approval.connected_account.with_lock do
        raise ReviewError, "This approval has already been revoked" if approval.reload.revoked?
        review = approval.connected_account.payment_readiness_reviews.create!(
          snapshot(approval).merge(
            decision: :revocation,
            parent_review: approval,
            actor_user: actor,
            reason: reason.to_s.strip
          )
        )
        ConnectedAccounts::Manager.refresh_readiness!(
          account: approval.connected_account,
          actor: actor,
          request: request,
          action: "connected_account.readiness_revoked"
        )
        record!(review, "payment_readiness.revoked", actor, request)
      end
      review
    rescue ActiveRecord::RecordInvalid, ActiveRecord::StatementInvalid,
      ConnectedAccounts::Manager::AccountError => e
      raise ReviewError, error_message(e)
    end

    def self.reject!(submission:, actor:, reason:, request: nil)
      raise ReviewError, "Only a submission can be rejected" unless submission.decision_submission?
      raise ReviewError, "This submission already has a decision" if submission.child_reviews.where(
        decision: [:approval, :rejection]
      ).exists?
      raise ReviewError, "A specific rejection reason is required" if reason.to_s.strip.blank?

      review = nil
      submission.connected_account.with_lock do
        if submission.reload.child_reviews.where(decision: [:approval, :rejection]).exists?
          raise ReviewError, "This submission already has a decision"
        end
        review = submission.connected_account.payment_readiness_reviews.create!(
          snapshot(submission).merge(
            decision: :rejection,
            parent_review: submission,
            actor_user: actor,
            reason: reason.to_s.strip
          )
        )
        record!(review, "payment_readiness.rejected", actor, request)
      end
      review
    rescue ActiveRecord::RecordInvalid, ActiveRecord::StatementInvalid => e
      raise ReviewError, error_message(e)
    end

    def self.snapshot(review)
      review.attributes.symbolize_keys.slice(*SNAPSHOT_FIELDS)
    end
    private_class_method :snapshot

    def self.record!(review, action, actor, request)
      AuditLogger.record!(
        action: action,
        auditable: review,
        actor: actor,
        organization: review.connected_account.organization,
        after_data: review.attributes.slice(
          "id", "connected_account_id", "parent_review_id", "decision", "evidence_reference",
          "evidence_digest", "provider_approval_reference", "merchant_of_record",
          "fee_tax_schedule_reference", "liability_schedule_reference", "controls",
          "effective_at", "expires_at", "provider_state_digest", "reason"
        ),
        request: request
      )
    end
    private_class_method :record!

    def self.error_message(error)
      return error.record.errors.full_messages.to_sentence if error.respond_to?(:record)
      return error.message if error.is_a?(ConnectedAccounts::Manager::AccountError)

      "Payment readiness evidence conflicts with an existing decision"
    end
    private_class_method :error_message
  end
end
