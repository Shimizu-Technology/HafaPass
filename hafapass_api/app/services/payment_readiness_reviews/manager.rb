# frozen_string_literal: true

module PaymentReadinessReviews
  class Manager
    class ReviewError < StandardError; end

    SNAPSHOT_FIELDS = %i[
      evidence_reference evidence_digest provider_approval_reference merchant_of_record
      fee_tax_schedule_reference liability_schedule_reference controls effective_at expires_at
      provider_state_digest review_kind reviewed_snapshot
    ].freeze

    def self.submit!(account:, attributes:, actor:, request: nil)
      snapshot = attributes.to_h.symbolize_keys.slice(*SNAPSHOT_FIELDS)
      snapshot[:controls] = snapshot.fetch(:controls, {}).to_h.transform_values do |value|
        ActiveModel::Type::Boolean.new.cast(value)
      end
      review = nil
      with_account_lock(account) do
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

    def self.approve!(submission:, actor:, request: nil, reason: nil)
      raise ReviewError, ConnectedAccount::BANK_UNAVAILABLE_REASON unless submission.connected_account.payout_supported?
      raise ReviewError, "A change request cannot be approved" if submission.review_kind == "manual_change_request"
      raise ReviewError, "Only a submission can be approved" unless submission.decision_submission?
      if submission.child_reviews.where(decision: [:approval, :rejection]).exists?
        raise ReviewError, "This submission already has a decision"
      end
      raise ReviewError, "The evidence approval window is not yet effective" if submission.effective_at > Time.current
      raise ReviewError, "The evidence approval window has expired" if submission.expires_at <= Time.current
      review = nil
      with_account_lock(submission.connected_account) do
        if submission.reload.child_reviews.where(decision: [:approval, :rejection]).exists?
          raise ReviewError, "This submission already has a decision"
        end
        raise ReviewError, "The evidence approval window is not yet effective" if submission.effective_at > Time.current
        raise ReviewError, "The evidence approval window has expired" if submission.expires_at <= Time.current
        unless submission.send(:provider_state_unchanged?)
          raise ReviewError, "Provider state changed; submit a new evidence snapshot"
        end
        if submission.connected_account.active_payment_readiness_approval
          raise ReviewError, "Revoke the current readiness approval before approving another"
        end
        review = submission.connected_account.payment_readiness_reviews.create!(
          snapshot(submission).merge(
            decision: :approval,
            parent_review: submission,
            actor_user: actor, reason: reason
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
      with_account_lock(approval.connected_account) do
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
      with_account_lock(submission.connected_account) do
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

    def self.with_account_lock(account, &block)
      account.organization.with_lock { account.with_lock(&block) }
    end
    private_class_method :with_account_lock

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
