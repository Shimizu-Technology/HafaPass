# frozen_string_literal: true

class LiveMoneyProofReview < ApplicationRecord
  ENTITY_FIELDS = %w[
    legal_entity_reference organizer_reference bank_account_reference provider_approval_reference
    charge_provider payout_provider production_environment
  ].freeze
  PROVIDER_FIELDS = %w[
    charge_reference charge_amount_cents currency partial_refund_reference partial_refund_amount_cents
    final_refund_reference final_refund_amount_cents initial_settlement_digest payout_reference
    payout_amount_cents bank_receipt_reference bank_receipt_digest bank_receipt_amount_cents
    post_payout_settlement_digest post_payout_negative_balance_cents
  ].freeze
  RECONCILIATION_FIELDS = %w[
    provider_charge_cents local_charge_cents charge_variance_cents provider_refund_cents local_refund_cents
    refund_variance_cents provider_processing_fee_cents local_processing_fee_cents processing_fee_variance_cents
    provider_payout_cents local_payout_cents bank_receipt_cents payout_variance_cents
    local_negative_balance_cents negative_balance_variance_cents open_reconciliation_exception_count
    open_dispute_count pending_refund_count
  ].freeze
  COMMUNICATION_KEYS = %w[
    buyer_charge_receipt buyer_partial_refund_notice buyer_final_refund_notice organizer_settlement_statement
    organizer_payout_notice support_order_trace
  ].freeze
  COMMUNICATION_FIELDS = %w[status evidence_reference].freeze
  CONTROL_KEYS = %w[
    actual_entity_verified actual_organizer_verified actual_bank_verified production_provider_verified
    live_charge_confirmed partial_refund_confirmed full_refund_confirmed initial_settlement_finalized
    payout_paid bank_receipt_confirmed post_payout_negative_balance_confirmed communications_confirmed
    zero_unexplained_variance no_open_exceptions explicit_go_decision
  ].freeze
  VARIANCE_FIELDS = %w[
    charge_variance_cents refund_variance_cents processing_fee_variance_cents payout_variance_cents
    negative_balance_variance_cents open_reconciliation_exception_count open_dispute_count pending_refund_count
  ].freeze

  belongs_to :organization
  belongs_to :connected_account
  belongs_to :proof_event, class_name: "Event", inverse_of: :live_money_proof_reviews
  belongs_to :event_day_rehearsal_review
  belongs_to :authorization, class_name: "LiveMoneyProofAuthorization", inverse_of: :live_money_proof_reviews
  belongs_to :order
  belongs_to :payment
  belongs_to :partial_refund, class_name: "Refund"
  belongs_to :final_refund, class_name: "Refund"
  belongs_to :initial_settlement, class_name: "Settlement"
  belongs_to :payout
  belongs_to :post_payout_settlement, class_name: "Settlement"
  belongs_to :parent_review, class_name: "LiveMoneyProofReview", optional: true
  belongs_to :actor_user, class_name: "User", inverse_of: :live_money_proof_reviews
  has_many :child_reviews, class_name: "LiveMoneyProofReview", foreign_key: :parent_review_id,
    dependent: :restrict_with_error, inverse_of: :parent_review

  enum :decision, { submission: 0, approval: 1, revocation: 2, rejection: 3 }, prefix: true

  validates :evidence_reference, :evidence_digest, :application_revision, :provider_state_digest,
    :platform_configuration_digest, :effective_at, :expires_at, presence: true
  validates :evidence_digest, :provider_state_digest, :platform_configuration_digest,
    format: { with: /\A[0-9a-f]{64}\z/ }
  validate :complete_entity_results
  validate :complete_provider_results
  validate :valid_reconciliation_results
  validate :complete_communication_results
  validate :complete_controls
  validate :valid_record_chain, if: -> { decision_submission? || decision_approval? }
  validate :valid_parent_relationship
  validate :independent_approver
  validate :parent_snapshot_matches
  validate :reason_present_for_negative_decision
  validate :valid_effective_window

  attr_readonly :organization_id, :connected_account_id, :proof_event_id, :event_day_rehearsal_review_id,
    :authorization_id, :order_id, :payment_id, :partial_refund_id, :final_refund_id,
    :initial_settlement_id, :payout_id, :post_payout_settlement_id, :parent_review_id, :actor_user_id,
    :decision, :evidence_reference, :evidence_digest, :application_revision, :provider_state_digest,
    :platform_configuration_digest, :entity_results, :provider_results, :reconciliation_results,
    :communication_results, :controls, :effective_at, :expires_at, :reason

  before_update :prevent_mutation
  before_destroy :prevent_mutation

  scope :approvals, -> { where(decision: :approval) }
  scope :revocations, -> { where(decision: :revocation) }

  def revoked?
    child_reviews.decision_revocation.exists?
  end

  private

  def complete_entity_results
    result = normalized_hash(entity_results)
    ENTITY_FIELDS.each do |field|
      errors.add(:entity_results, "must include #{field}") if result[field].to_s.strip.blank?
    end
    errors.add(:entity_results, "charge provider must be stripe") unless result["charge_provider"] == "stripe"
    if connected_account && result["payout_provider"].present? && result["payout_provider"] != connected_account.provider
      errors.add(:entity_results, "payout provider must match the connected account")
    end
    unless ActiveModel::Type::Boolean.new.cast(result["production_environment"])
      errors.add(:entity_results, "must confirm the production environment")
    end
  end

  def complete_provider_results
    result = normalized_hash(provider_results)
    PROVIDER_FIELDS.each do |field|
      errors.add(:provider_results, "must include #{field}") if result[field].to_s.strip.blank?
    end
    errors.add(:provider_results, "currency must be usd") unless result["currency"].to_s.downcase == "usd"
    %w[initial_settlement_digest bank_receipt_digest post_payout_settlement_digest].each do |field|
      errors.add(:provider_results, "#{field} must be a SHA-256") unless sha256?(result[field])
    end
    integer_fields = PROVIDER_FIELDS.grep(/_cents\z/)
    values = integer_fields.index_with { |field| integer_value(result[field], :provider_results, field) }
    return if errors[:provider_results].any?

    errors.add(:provider_results, "money amounts must be positive") unless values.values.all?(&:positive?)
  end

  def valid_reconciliation_results
    result = normalized_hash(reconciliation_results)
    values = RECONCILIATION_FIELDS.index_with do |field|
      integer_value(result[field], :reconciliation_results, field)
    end
    return if errors[:reconciliation_results].any?

    errors.add(:reconciliation_results, "money facts cannot be negative") if values.except(*VARIANCE_FIELDS).values.any?(&:negative?)
    VARIANCE_FIELDS.each do |field|
      errors.add(:reconciliation_results, "#{field} must be zero") unless values[field].zero?
    end
    compare_pair(values, "provider_charge_cents", "local_charge_cents", "charge totals")
    compare_pair(values, "provider_refund_cents", "local_refund_cents", "refund totals")
    compare_pair(values, "provider_processing_fee_cents", "local_processing_fee_cents", "processing fees")
    unless values["provider_payout_cents"] == values["local_payout_cents"] &&
        values["local_payout_cents"] == values["bank_receipt_cents"]
      errors.add(:reconciliation_results, "provider, local, and bank payout totals must match")
    end
  end

  def complete_communication_results
    results = normalized_hash(communication_results)
    COMMUNICATION_KEYS.each do |key|
      result = normalized_hash(results[key])
      errors.add(:communication_results, "must confirm #{key}") unless result["status"] == "confirmed"
      if result["evidence_reference"].to_s.strip.blank?
        errors.add(:communication_results, "must include #{key}.evidence_reference")
      end
    end
  end

  def complete_controls
    result = normalized_hash(controls)
    missing = CONTROL_KEYS.reject { |key| result[key] == true }
    errors.add(:controls, "must affirm: #{missing.join(', ')}") if missing.any?
  end

  def valid_record_chain
    records = [connected_account, proof_event, event_day_rehearsal_review, authorization, order, payment,
      partial_refund, final_refund, initial_settlement, payout, post_payout_settlement]
    return if records.any?(&:nil?)

    validate_relationships
    validate_real_provider_records
    validate_financial_sequence
    validate_recorded_facts
  end

  def validate_relationships
    event_records_match = event_day_rehearsal_review.event_id == proof_event_id && authorization.event_id == proof_event_id &&
      order.event_id == proof_event_id && initial_settlement.event_id == proof_event_id && payout.event_id == proof_event_id &&
      post_payout_settlement.event_id == proof_event_id
    errors.add(:base, "Every proof record must belong to the proof event") unless event_records_match
    organization_records_match = proof_event.organization_id == organization_id && connected_account.organization_id == organization_id &&
      initial_settlement.organization_id == organization_id && payout.organization_id == organization_id &&
      post_payout_settlement.organization_id == organization_id
    errors.add(:base, "Every proof record must belong to the organization") unless organization_records_match
    order_records_match = payment.order_id == order_id && partial_refund.order_id == order_id && final_refund.order_id == order_id
    errors.add(:base, "Payment and refunds must belong to the proof order") unless order_records_match
    errors.add(:authorization, "must be consumed by the proof order") unless authorization.order_id == order_id
    errors.add(:payout, "must use the proof connected account and initial settlement") unless
      payout.connected_account_id == connected_account_id && payout.settlement_id == initial_settlement_id
  end

  def validate_real_provider_records
    errors.add(:proof_event, "must be a live-money proof candidate") unless proof_event.live_money_proof_candidate?
    errors.add(:order, "must be a completed live charge of $5 or less") unless
      order.total_cents.between?(1, LiveMoneyProofAuthorization::MAX_AMOUNT_CENTS) && order.refunded?
    errors.add(:payment, "must be a fully refunded Stripe payment") unless payment.provider == "stripe" && payment.refunded?
    if simulated_reference?(payment.provider_payment_id)
      errors.add(:payment, "must use a real provider payment reference")
    end
    [partial_refund, final_refund].each do |refund|
      errors.add(:base, "Both refunds must succeed with real provider references") unless
        refund.succeeded? && !simulated_reference?(refund.provider_refund_id)
    end
    errors.add(:payout, "must be paid with a real provider or bank reference") unless
      payout.status_paid? && !simulated_reference?(payout.provider_payout_id)
  end

  def validate_financial_sequence
    errors.add(:partial_refund, "must be positive and less than the charge") unless
      partial_refund.amount_cents.positive? && partial_refund.amount_cents < payment.amount_cents
    errors.add(:final_refund, "must complete the full refund") unless
      partial_refund.amount_cents + final_refund.amount_cents == payment.amount_cents
    errors.add(:initial_settlement, "must be finalized with enough payable balance") unless
      initial_settlement.status_finalized? && initial_settlement.payable_cents >= payout.amount_cents
    errors.add(:post_payout_settlement, "must be a later finalized negative-balance version") unless
      post_payout_settlement.status_finalized? && post_payout_settlement.version > initial_settlement.version &&
      post_payout_settlement.negative_balance_cents.positive?
    current_digest = Settlements::Calculator.call(proof_event).attributes[:source_digest]
    errors.add(:post_payout_settlement, "must match the current proof ledger") unless
      post_payout_settlement.source_digest == current_digest
    times = [partial_refund.succeeded_at, initial_settlement.finalized_at, payout.paid_at,
      final_refund.succeeded_at, post_payout_settlement.finalized_at]
    unless times.all? && times.each_cons(2).all? { |before_time, after_time| before_time <= after_time }
      errors.add(:base, "Proof must run partial refund, settlement, payout, final refund, then negative-balance settlement")
    end
  end

  def validate_recorded_facts
    provider = normalized_hash(provider_results)
    reconciliation = normalized_hash(reconciliation_results)
    processing_fee = FeeComponent.where(order: order, kind: :processing, estimated: false).sum(:amount_cents)
    expected_provider = {
      "charge_reference" => payment.provider_payment_id, "charge_amount_cents" => payment.amount_cents,
      "partial_refund_reference" => partial_refund.provider_refund_id,
      "partial_refund_amount_cents" => partial_refund.amount_cents,
      "final_refund_reference" => final_refund.provider_refund_id,
      "final_refund_amount_cents" => final_refund.amount_cents,
      "initial_settlement_digest" => initial_settlement.source_digest,
      "payout_reference" => payout.provider_payout_id, "payout_amount_cents" => payout.amount_cents,
      "bank_receipt_amount_cents" => payout.amount_cents,
      "post_payout_settlement_digest" => post_payout_settlement.source_digest,
      "post_payout_negative_balance_cents" => post_payout_settlement.negative_balance_cents
    }
    expected_provider.each do |field, value|
      errors.add(:provider_results, "#{field} must match the local proof record") unless provider[field].to_s == value.to_s
    end
    expected_reconciliation = {
      "local_charge_cents" => payment.amount_cents,
      "local_refund_cents" => partial_refund.amount_cents + final_refund.amount_cents,
      "local_processing_fee_cents" => processing_fee,
      "local_payout_cents" => payout.amount_cents,
      "bank_receipt_cents" => payout.amount_cents,
      "local_negative_balance_cents" => post_payout_settlement.negative_balance_cents,
      "open_reconciliation_exception_count" => order.reconciliation_exceptions.open.count,
      "open_dispute_count" => order.disputes.open.count,
      "pending_refund_count" => order.refunds.pending.count
    }
    expected_reconciliation.each do |field, value|
      errors.add(:reconciliation_results, "#{field} must match the local proof ledger") unless
        reconciliation[field].to_s == value.to_s
    end
  end

  def compare_pair(values, left, right, label)
    errors.add(:reconciliation_results, "#{label} must match") unless values[left] == values[right]
  end

  def valid_parent_relationship
    if decision_submission?
      errors.add(:parent_review, "must be absent for a submission") if parent_review
      return
    end
    if parent_review.nil?
      errors.add(:parent_review, "is required")
    elsif decision_approval? && !parent_review.decision_submission?
      errors.add(:parent_review, "must be a submission")
    elsif decision_revocation? && !parent_review.decision_approval?
      errors.add(:parent_review, "must be an approval")
    elsif decision_rejection? && !parent_review.decision_submission?
      errors.add(:parent_review, "must be a submission")
    elsif parent_review.organization_id != organization_id
      errors.add(:parent_review, "must belong to the same organization")
    end
  end

  def independent_approver
    return unless decision_approval? && parent_review && actor_user_id == parent_review.actor_user_id

    errors.add(:actor_user, "must be independent from the evidence submitter")
  end

  def parent_snapshot_matches
    return unless parent_review

    fields = self.class.readonly_attributes.excluding("parent_review_id", "actor_user_id", "decision", "reason")
    errors.add(:base, "Evidence snapshot must match the parent review") unless fields.all? do |field|
      public_send(field) == parent_review.public_send(field)
    end
  end

  def reason_present_for_negative_decision
    return unless (decision_revocation? || decision_rejection?) && reason.to_s.strip.blank?

    errors.add(:reason, "is required for a revocation or rejection")
  end

  def valid_effective_window
    return if effective_at.blank? || expires_at.blank?

    errors.add(:expires_at, "must be after the effective time") unless expires_at > effective_at
  end

  def integer_value(value, attribute, field)
    Integer(value, exception: true)
  rescue ArgumentError, TypeError
    errors.add(attribute, "#{field} must be an integer")
    nil
  end

  def normalized_hash(value)
    value.respond_to?(:to_h) ? value.to_h.stringify_keys : {}
  end

  def sha256?(value)
    value.to_s.match?(/\A[0-9a-f]{64}\z/)
  end

  def simulated_reference?(value)
    value.to_s.blank? || value.to_s.start_with?("sim_")
  end

  def prevent_mutation
    errors.add(:base, "Live-money proof evidence is append-only")
    throw(:abort)
  end
end
