# frozen_string_literal: true

module LiveMoneyProofReviews
  class Manager
    class ReviewError < StandardError; end

    SNAPSHOT_FIELDS = %i[
      connected_account_id proof_event_id event_day_rehearsal_review_id authorization_id order_id payment_id
      partial_refund_id final_refund_id initial_settlement_id payout_id post_payout_settlement_id
      evidence_reference evidence_digest application_revision provider_state_digest platform_configuration_digest
      entity_results provider_results reconciliation_results communication_results controls effective_at expires_at
    ].freeze

    def self.submit!(organization:, attributes:, actor:, request: nil)
      validate_admin!(actor)
      review = nil
      organization.with_lock do
        account = organization.payout_account
        unless LiveMoneyProof.provider_ready?(account)
          raise ReviewError, "Current live Stripe and payout readiness approvals are required first"
        end
        if LiveMoneyProof.active_approval(organization, connected_account: account)
          raise ReviewError, "Revoke the current Gate H approval before submitting another"
        end
        if LiveMoneyProof.pending_submission(organization)
          raise ReviewError, "Decide the current Gate H submission before submitting another"
        end

        snapshot = normalize_snapshot(attributes.to_h.symbolize_keys.slice(*SNAPSHOT_FIELDS))
        snapshot[:connected_account_id] = account.id
        snapshot[:application_revision] = PilotReadiness.application_revision
        snapshot[:provider_state_digest] = account.readiness_state_digest
        snapshot[:platform_configuration_digest] = LiveMoneyProof.platform_configuration_digest
        review = organization.live_money_proof_reviews.create!(
          snapshot.merge(decision: :submission, actor_user: actor)
        )
        validate_current_prerequisites!(review)
        record!(review, "live_money_proof.submitted", actor, request)
      end
      review
    rescue ActiveRecord::RecordInvalid, ActiveRecord::StatementInvalid => e
      raise ReviewError, error_message(e)
    end

    def self.approve!(submission:, actor:, request: nil)
      validate_admin!(actor)
      review = nil
      submission.organization.with_lock do
        submission.reload
        validate_open_submission!(submission, actor: actor, approving: true)
        raise ReviewError, "The live-money evidence window is not yet effective" if submission.effective_at > Time.current
        raise ReviewError, "The live-money evidence window has expired" if submission.expires_at <= Time.current
        validate_current_prerequisites!(submission)
        unless submission.valid?
          raise ReviewError, submission.errors.full_messages.to_sentence
        end
        if LiveMoneyProof.active_approval(submission.organization, connected_account: submission.connected_account)
          raise ReviewError, "Revoke the current Gate H approval before approving another"
        end

        review = submission.organization.live_money_proof_reviews.create!(snapshot(submission).merge(
          decision: :approval, parent_review: submission, actor_user: actor
        ))
        record!(review, "live_money_proof.approved", actor, request)
      end
      review
    rescue ActiveRecord::RecordInvalid, ActiveRecord::RecordNotUnique, ActiveRecord::StatementInvalid => e
      raise ReviewError, error_message(e)
    end

    def self.reject!(submission:, actor:, reason:, request: nil)
      validate_admin!(actor)
      raise ReviewError, "A specific rejection reason is required" if reason.to_s.strip.blank?
      review = nil
      submission.organization.with_lock do
        submission.reload
        validate_open_submission!(submission, actor: actor)
        review = submission.organization.live_money_proof_reviews.create!(snapshot(submission).merge(
          decision: :rejection, parent_review: submission, actor_user: actor, reason: reason.to_s.strip
        ))
        record!(review, "live_money_proof.rejected", actor, request)
      end
      review
    rescue ActiveRecord::RecordInvalid, ActiveRecord::RecordNotUnique, ActiveRecord::StatementInvalid => e
      raise ReviewError, error_message(e)
    end

    def self.revoke!(approval:, actor:, reason:, request: nil)
      validate_admin!(actor)
      raise ReviewError, "A specific revocation reason is required" if reason.to_s.strip.blank?
      review = nil
      approval.organization.with_lock do
        approval.reload
        raise ReviewError, "Only an approval can be revoked" unless approval.decision_approval?
        raise ReviewError, "This approval has already been revoked" if approval.revoked?
        review = approval.organization.live_money_proof_reviews.create!(snapshot(approval).merge(
          decision: :revocation, parent_review: approval, actor_user: actor, reason: reason.to_s.strip
        ))
        record!(review, "live_money_proof.revoked", actor, request)
      end
      review
    rescue ActiveRecord::RecordInvalid, ActiveRecord::RecordNotUnique, ActiveRecord::StatementInvalid => e
      raise ReviewError, error_message(e)
    end

    def self.validate_current_prerequisites!(review)
      account = review.organization.payout_account
      unless account&.id == review.connected_account_id &&
          review.provider_state_digest == account.readiness_state_digest &&
          review.platform_configuration_digest == LiveMoneyProof.platform_configuration_digest &&
          review.application_revision == PilotReadiness.application_revision && LiveMoneyProof.provider_ready?(account)
        raise ReviewError, "Provider, payout account, capability, or application state changed; submit new Gate H evidence"
      end
      event_state = PilotReadiness.event_state_digest(review.proof_event)
      rehearsal = EventDayRehearsal.active_approval(review.proof_event, state_digest: event_state)
      unless rehearsal&.id == review.event_day_rehearsal_review_id
        raise ReviewError, "The proof event no longer has the exact current Gate G approval"
      end
    end
    private_class_method :validate_current_prerequisites!

    def self.validate_open_submission!(submission, actor:, approving: false)
      raise ReviewError, "Only a submission can be decided" unless submission.decision_submission?
      if submission.child_reviews.where(decision: [:approval, :rejection]).exists?
        raise ReviewError, "This live-money submission already has a decision"
      end
      if approving && submission.actor_user_id == actor.id
        raise ReviewError, "The submitter cannot approve their own live-money evidence"
      end
    end
    private_class_method :validate_open_submission!

    def self.validate_admin!(actor)
      raise ReviewError, "Only an administrator can manage Gate H evidence" unless actor&.admin?
    end
    private_class_method :validate_admin!

    def self.snapshot(review)
      review.attributes.symbolize_keys.slice(*SNAPSHOT_FIELDS)
    end
    private_class_method :snapshot

    def self.normalize_snapshot(snapshot)
      snapshot[:entity_results] = safe_hash(snapshot[:entity_results]).slice(*LiveMoneyProofReview::ENTITY_FIELDS)
      snapshot[:provider_results] = normalize_integers(
        safe_hash(snapshot[:provider_results]).slice(*LiveMoneyProofReview::PROVIDER_FIELDS),
        LiveMoneyProofReview::PROVIDER_FIELDS.grep(/_cents\z/)
      )
      snapshot[:reconciliation_results] = normalize_integers(
        safe_hash(snapshot[:reconciliation_results]).slice(*LiveMoneyProofReview::RECONCILIATION_FIELDS),
        LiveMoneyProofReview::RECONCILIATION_FIELDS
      )
      snapshot[:communication_results] = safe_hash(snapshot[:communication_results])
        .slice(*LiveMoneyProofReview::COMMUNICATION_KEYS).transform_values do |value|
          safe_hash(value).slice(*LiveMoneyProofReview::COMMUNICATION_FIELDS)
        end
      snapshot[:controls] = safe_hash(snapshot[:controls]).slice(*LiveMoneyProofReview::CONTROL_KEYS)
        .transform_values { |value| ActiveModel::Type::Boolean.new.cast(value) }
      snapshot
    end
    private_class_method :normalize_snapshot

    def self.normalize_integers(result, fields)
      fields.each { |field| result[field] = Integer(result[field], exception: false) || result[field] if result.key?(field) }
      result
    end
    private_class_method :normalize_integers

    def self.safe_hash(value)
      value.respond_to?(:to_h) ? value.to_h.stringify_keys : {}
    end
    private_class_method :safe_hash

    def self.record!(review, action, actor, request)
      communication_summary = review.communication_results.transform_values do |result|
        { "status" => result.to_h["status"] }
      end
      AuditLogger.record!(
        action: action, auditable: review, actor: actor, organization: review.organization,
        after_data: review.attributes.slice(
          "id", "organization_id", "connected_account_id", "proof_event_id", "event_day_rehearsal_review_id",
          "authorization_id", "order_id", "payment_id", "partial_refund_id", "final_refund_id",
          "initial_settlement_id", "payout_id", "post_payout_settlement_id", "parent_review_id",
          "actor_user_id", "decision", "evidence_digest", "application_revision", "provider_state_digest",
          "platform_configuration_digest", "reconciliation_results", "controls", "effective_at", "expires_at",
          "reason"
        ).merge("entity_results" => { "production_environment" => review.entity_results["production_environment"] },
          "provider_results" => review.provider_results.slice(
            "charge_amount_cents", "partial_refund_amount_cents", "final_refund_amount_cents",
            "payout_amount_cents", "bank_receipt_amount_cents", "post_payout_negative_balance_cents"
          ), "communication_results" => communication_summary),
        request: request
      )
    end
    private_class_method :record!

    def self.error_message(error)
      return error.record.errors.full_messages.to_sentence if error.respond_to?(:record)

      error.message.presence || "Live-money proof evidence conflicts with an existing decision"
    end
    private_class_method :error_message
  end
end
