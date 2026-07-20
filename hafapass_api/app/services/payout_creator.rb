# frozen_string_literal: true

class PayoutCreator
  class PayoutError < StandardError; end

  def self.call(**)
    new(**).call
  end

  def initialize(settlement:, actor:, idempotency_key:, amount_cents: nil, request: nil)
    @settlement = settlement
    @actor = actor
    @idempotency_key = idempotency_key
    @requested_amount_cents = amount_cents&.to_i
    @request = request
  end

  def call
    existing = Payout.find_by(idempotency_key: idempotency_key)
    return validate_idempotent_replay!(existing) if existing

    payout = reserve!
    result = PayoutGateway.submit(payout)
    payout.update!(
      provider_payout_id: result.provider_payout_id,
      status: result.status,
      initiated_at: Time.current,
      paid_at: result.status == :paid ? Time.current : nil
    )
    AuditLogger.record!(
      action: "payout.#{payout.status}",
      auditable: payout,
      actor: actor,
      organization: payout.organization,
      metadata: { amount_cents: payout.amount_cents, settlement_id: settlement.id },
      request: request
    )
    payout
  rescue PayoutGateway::PayoutError => e
    payout&.update!(status: :failed, failure_code: "provider_unavailable", failure_message: e.message)
    raise PayoutError, e.message
  rescue ActiveRecord::RecordInvalid => e
    raise PayoutError, e.record.errors.full_messages.to_sentence
  end

  private

  attr_reader :settlement, :actor, :idempotency_key, :requested_amount_cents, :request

  def reserve!
    Payout.transaction do
      settlement.organization.lock!
      settlement.lock!
      raise PayoutError, "Settlement must be finalized" unless settlement.status_finalized?
      current_digest = Settlements::Calculator.call(settlement.event).attributes[:source_digest]
      if current_digest != settlement.source_digest
        raise PayoutError, "Financial activity changed; finalize a new settlement before paying out"
      end

      account = settlement.organization.payout_account
      raise PayoutError, "A payout-ready connected account is required" unless account

      available = [
        settlement.available_to_payout_cents,
        OrganizationPayoutBalance.available_cents(settlement.organization)
      ].min
      amount = requested_amount_cents || available
      raise PayoutError, "Payout amount must be positive" unless amount.positive?
      raise PayoutError, "Payout amount exceeds the available balance" if amount > available

      settlement.payouts.create!(
        organization: settlement.organization,
        event: settlement.event,
        connected_account: account,
        provider: account.provider,
        idempotency_key: idempotency_key,
        amount_cents: amount,
        currency: settlement.currency,
        status: :pending
      )
    end
  rescue ActiveRecord::RecordNotUnique
    validate_idempotent_replay!(Payout.find_by!(idempotency_key: idempotency_key))
  end

  def validate_idempotent_replay!(payout)
    requested_amount_matches = requested_amount_cents.nil? || requested_amount_cents == payout.amount_cents
    unless payout.settlement_id == settlement.id && requested_amount_matches
      raise PayoutError, "Idempotency-Key was already used for a different payout request"
    end

    payout
  end
end
