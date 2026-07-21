# frozen_string_literal: true

class LiveMoneyProof
  CHARGE_PROVIDER = "stripe"

  def self.platform_configuration_digest
    Digest::SHA256.hexdigest(JSON.generate(
      charge_provider: CHARGE_PROVIDER,
      payment_mode: SiteSetting.instance.payment_mode,
      capability_digest: PlatformCapabilities.configuration_digest("stripe_live")
    ))
  end

  def self.active_approval(organization, at: Time.current, connected_account: nil)
    connected_account ||= organization.payout_account
    return unless provider_ready?(connected_account)

    revoked_ids = organization.live_money_proof_reviews.revocations.select(:parent_review_id)
    organization.live_money_proof_reviews.approvals
      .where.not(id: revoked_ids)
      .where(connected_account_id: connected_account.id)
      .where(provider_state_digest: connected_account.readiness_state_digest)
      .where(platform_configuration_digest: platform_configuration_digest)
      .where(application_revision: PilotReadiness.application_revision)
      .where("effective_at <= ? AND expires_at > ?", at, at)
      .order(created_at: :desc).first
  end

  def self.pending_submission(organization)
    decided_ids = organization.live_money_proof_reviews.where(decision: [:approval, :rejection])
      .select(:parent_review_id)
    organization.live_money_proof_reviews.decision_submission.where.not(id: decided_ids)
      .where("expires_at > ?", Time.current).order(created_at: :desc).first
  end

  def self.latest_approval(organization)
    organization.live_money_proof_reviews.approvals.order(created_at: :desc).first
  end

  def self.status(organization)
    account = organization.payout_account
    approval = active_approval(organization, connected_account: account)
    latest = latest_approval(organization)
    {
      required: Rails.env.production?, prerequisite_ready: provider_ready?(account), approved: approval.present?,
      candidate_current: latest.present? && account.present? && latest.connected_account_id == account.id &&
        latest.provider_state_digest == account.readiness_state_digest &&
        latest.platform_configuration_digest == platform_configuration_digest &&
        latest.application_revision == PilotReadiness.application_revision,
      connected_account_id: account&.id, pending_submission: pending_submission(organization),
      latest_approval: latest, active_approval_id: approval&.id,
      required_controls: LiveMoneyProofReview::CONTROL_KEYS,
      application_revision: PilotReadiness.application_revision,
      platform_configuration_digest: platform_configuration_digest
    }
  end

  def self.provider_ready?(account)
    SiteSetting.instance.live_mode? && PlatformCapabilities.enabled?("stripe_live") && account&.payout_ready?
  end

  def self.list_summary(organization)
    reviews = organization.live_money_proof_reviews.to_a
    decided_ids = reviews.filter_map do |review|
      review.parent_review_id if review.decision_approval? || review.decision_rejection?
    end
    pending = reviews.select do |review|
      review.decision_submission? && review.expires_at > Time.current && !decided_ids.include?(review.id)
    end.max_by(&:created_at)
    latest = reviews.select(&:decision_approval?).max_by(&:created_at)
    { approval_recorded: latest.present?, pending_submission: pending && { id: pending.id, created_at: pending.created_at } }
  end
end
