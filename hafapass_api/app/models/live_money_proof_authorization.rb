# frozen_string_literal: true

class LiveMoneyProofAuthorization < ApplicationRecord
  MAX_AMOUNT_CENTS = 500

  belongs_to :event
  belongs_to :connected_account
  belongs_to :event_day_rehearsal_review
  belongs_to :requested_by_user, class_name: "User", inverse_of: :requested_live_money_proof_authorizations
  belongs_to :approved_by_user, class_name: "User", optional: true,
    inverse_of: :approved_live_money_proof_authorizations
  belongs_to :order, optional: true
  has_many :live_money_proof_reviews, foreign_key: :authorization_id, dependent: :restrict_with_error,
    inverse_of: :authorization

  validates :buyer_email_digest, :event_state_digest, :application_revision, :provider_state_digest,
    :platform_configuration_digest, :expires_at, presence: true
  validates :buyer_email_digest, :event_state_digest, :provider_state_digest, :platform_configuration_digest,
    format: { with: /\A[0-9a-f]{64}\z/ }
  validates :max_amount_cents, numericality: {
    only_integer: true, greater_than: 0, less_than_or_equal_to: MAX_AMOUNT_CENTS
  }
  validate :relationships_match
  validate :approval_is_independent
  validate :valid_state_pairs

  attr_readonly :event_id, :connected_account_id, :event_day_rehearsal_review_id, :requested_by_user_id,
    :buyer_email_digest, :max_amount_cents, :event_state_digest, :application_revision,
    :provider_state_digest, :platform_configuration_digest, :expires_at, :created_at

  def self.email_digest(value)
    Digest::SHA256.hexdigest(value.to_s.strip.downcase)
  end

  def approved?
    approved_at.present? && approved_by_user_id.present?
  end

  def consumed?
    consumed_at.present? || order_id.present?
  end

  def revoked?
    revoked_at.present?
  end

  def available_for?(user:, buyer_email:, at: Time.current)
    approved? && !consumed? && !revoked? && expires_at > at && user&.admin? &&
      buyer_email_digest == self.class.email_digest(buyer_email) && current_bindings?(at: at)
  end

  def current_bindings?(at: Time.current)
    state_digest = PilotReadiness.event_state_digest(event)
    rehearsal = EventDayRehearsal.active_approval(event, at: at, state_digest: state_digest)
    account = event.organization.payout_account
    event.live_money_proof_candidate? && event.published? && event.live_money_proof_candidate_configured? &&
      rehearsal&.id == event_day_rehearsal_review_id && state_digest == event_state_digest &&
      application_revision == PilotReadiness.application_revision && account&.id == connected_account_id &&
      provider_state_digest == connected_account.readiness_state_digest &&
      platform_configuration_digest == LiveMoneyProof.platform_configuration_digest &&
      LiveMoneyProof.provider_ready?(connected_account)
  end

  private

  def relationships_match
    return if event.nil? || connected_account.nil? || event_day_rehearsal_review.nil?

    errors.add(:connected_account, "must belong to the proof event organization") unless
      connected_account.organization_id == event.organization_id
    errors.add(:event_day_rehearsal_review, "must belong to the proof event") unless
      event_day_rehearsal_review.event_id == event_id
    errors.add(:order, "must belong to the proof event") if order && order.event_id != event_id
  end

  def approval_is_independent
    return unless approved_by_user_id && approved_by_user_id == requested_by_user_id

    errors.add(:approved_by_user, "must be independent from the requester")
  end

  def valid_state_pairs
    if approved_at.present? != approved_by_user_id.present?
      errors.add(:base, "Approval actor and timestamp must be recorded together")
    end
    errors.add(:base, "Consumed order and timestamp must be recorded together") if consumed_at.present? != order_id.present?
    if revoked_at.present? != revocation_reason.to_s.strip.present?
      errors.add(:base, "Revocation timestamp and reason must be recorded together")
    end
  end
end
