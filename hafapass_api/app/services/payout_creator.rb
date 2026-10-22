# frozen_string_literal: true

class PayoutCreator
  class PayoutError < StandardError; end

  def self.call(**)
    new(**).call
  end

  def initialize(settlement:, actor:, idempotency_key:, amount_cents: nil, request: nil, withholding_override_reason: nil)
    @settlement = settlement
    @actor = actor
    @idempotency_key = idempotency_key
    @requested_amount_cents = amount_cents&.to_i
    @request = request
    @withholding_override_reason = withholding_override_reason
  end

  def call
    existing = Payout.find_by(idempotency_key: idempotency_key)
    return validate_idempotent_replay!(existing) if existing

    payout, reserved = reserve!
    return payout unless reserved

    result = submit_payout!(payout)
    record_submission_outcome!(payout,
      provider_payout_id: result.provider_payout_id,
      status: result.status,
      initiated_at: Time.current,
      paid_at: result.status.to_s == "paid" ? Time.current : nil
    )
    payout
  rescue ActiveRecord::RecordInvalid => e
    raise PayoutError, e.record.errors.full_messages.to_sentence
  end

  private

  attr_reader :settlement, :actor, :idempotency_key, :requested_amount_cents, :request, :withholding_override_reason

  def submit_payout!(payout)
    payout.organization.with_lock do
      payout.with_lock do
        raise PayoutError, "Payout was held before submission" unless payout.status_pending?

        PayoutWithholdingGuard.call(payout: payout, actor: actor, request: request)
      end
    end
    PayoutGateway.submit(payout)
  rescue PayoutWithholdingGuard::WithholdingError => e
    raise PayoutError, e.message
  rescue PayoutGateway::PayoutError => e
    record_submission_error!(
      payout,
      status: :failed,
      failure_code: "provider_unavailable",
      failure_message: e.message
    )
    raise PayoutError, e.message
  rescue PayoutError
    raise
  rescue StandardError => e
    # A timeout or unexpected adapter exception can leave the provider result
    # ambiguous. Keep the amount committed until finance reconciles it so a
    # retry cannot create a duplicate payout.
    record_submission_error!(
      payout,
      status: :processing,
      failure_code: "provider_result_unknown",
      failure_message: e.message
    )
    Sentry.capture_exception(e)
    raise PayoutError, "Payout provider result is unknown; reconcile this payout before retrying"
  end

  def record_submission_error!(payout, status:, failure_code:, failure_message:)
    record_submission_outcome!(payout, status: status, initiated_at: Time.current,
      failure_code: failure_code, failure_message: failure_message)
  end

  def record_submission_outcome!(payout, **attributes)
    Payout.transaction do
      payout.organization.lock!
      payout.lock!
      provider_result = attributes.dup
      withholding_review = false
      if %w[paid processing].include?(attributes[:status].to_s)
        begin
          PayoutWithholdingGuard.call(payout: payout, actor: actor, request: request,
            allow_recalculation: false)
        rescue PayoutWithholdingGuard::WithholdingError
          withholding_review = true
          attributes = attributes.merge(status: :processing, failure_code: "withholding_review_required",
            failure_message: "Provider outcome needs withholding review before payment can be recorded")
        end
      end
      before_data = payout.attributes.slice("status", "provider_payout_id", "paid_at")
      terminal = payout.status_paid? || payout.status_failed? || payout.status_reversed?
      incoming_paid = attributes[:status].to_s == "paid"
      same_transfer = payout.provider_payout_id == attributes[:provider_payout_id]
      conflict = terminal && incoming_paid && (payout.status_failed? || !same_transfer)
      action = withholding_review ? "payout.withholding_review_required" : "payout.#{attributes.fetch(:status)}"
      if payout.status_held?
        if incoming_paid
          payout.update!(provider_payout_id: attributes[:provider_payout_id] || payout.provider_payout_id,
            initiated_at: attributes[:initiated_at] || payout.initiated_at,
            failure_code: "provider_result_conflict",
            failure_message: "Provider reported payment after cancellation hold; reconcile before recording")
          action = "payout.provider_result_conflict"
        elsif attributes[:provider_payout_id].present? || attributes[:status].to_s == "processing"
          payout.update!(provider_payout_id: attributes[:provider_payout_id] || payout.provider_payout_id,
            initiated_at: attributes[:initiated_at] || payout.initiated_at,
            failure_code: "provider_result_conflict",
            failure_message: "Provider reported an in-flight transfer after cancellation hold; reconcile before releasing")
          action = "payout.provider_result_conflict"
        else
          action = "payout.late_result_held"
        end
      elsif conflict
        # Conflicting transfer evidence cannot silently release funds or erase
        # the operator's evidence. Reopen review, retaining the old identity in
        # the row and both outcomes in the immutable audit trail.
        payout.update!(status: :processing, failure_code: "provider_result_conflict",
          failure_message: "Late provider payment conflicts with a recorded outcome; reconcile before retrying")
        action = "payout.provider_result_conflict"
      elsif terminal
        action = "payout.late_result_ignored"
      else
        payout.update!(attributes)
      end
      AuditLogger.record!(action: action, auditable: payout, actor: actor,
        organization: payout.organization, before_data: before_data,
        after_data: payout.attributes.slice("status", "provider_payout_id", "paid_at"),
        metadata: { amount_cents: payout.amount_cents, settlement_id: settlement.id,
          failure_code: attributes[:failure_code], provider_result: provider_result }, request: request)
    end
  end

  def reserve!
    Payout.transaction do
      settlement.organization.lock!
      settlement.event.lock!
      settlement.lock!
      existing = Payout.find_by(idempotency_key: idempotency_key)
      return [validate_idempotent_replay!(existing), false] if existing

      raise PayoutError, "Settlement must be finalized" unless settlement.status_finalized?
      if EventCancellationRefunds.unresolved?(settlement.event)
        raise PayoutError, "Finish cancellation refunds before paying out this event"
      end
      if RefundReconciliationQueue.outstanding_for_event?(settlement.event)
        raise PayoutError, "Resolve outstanding refund liabilities before paying out this event"
      end
      current_digest = Settlements::Calculator.call(settlement.event).attributes[:source_digest]
      if current_digest != settlement.source_digest
        raise PayoutError, "Financial activity changed; finalize a new settlement before paying out"
      end

      tax = settlement.organization.organizer_tax_information
      withholding_review = tax.nil? || tax.certified_at.nil? || tax.backup_withholding_required?
      account = settlement.organization.payout_account
      if account.nil? && withholding_review
        account = settlement.organization.connected_accounts.find do |candidate|
          candidate.externally_ready? && candidate.active_payment_readiness_approval.present?
        end
      end
      raise PayoutError, "A payout-ready connected account is required" unless account

      available = [
        settlement.available_to_payout_cents,
        OrganizationPayoutBalance.available_cents(settlement.organization)
      ].min
      amount = requested_amount_cents || available
      raise PayoutError, "Payout amount must be positive" unless amount.positive?
      raise PayoutError, "Payout amount exceeds the available balance" if amount > available

      withholding = BackupWithholding.for_payout(organization: settlement.organization,
        amount_cents: amount, actor: actor, override_reason: withholding_override_reason)

      payout = settlement.payouts.create!(
        organization: settlement.organization,
        event: settlement.event,
        connected_account: account,
        provider: account.provider,
        idempotency_key: idempotency_key,
        amount_cents: amount,
        currency: settlement.currency,
        status: :pending,
        payee_snapshot: account.check_payee,
        payee_approval_digest: account.provider == "check" ? account.readiness_state_digest : nil,
        tax_information_snapshot: Payout.tax_snapshot(tax), tax_information_tin: tax&.tin,
        tax_approval_digest: account.readiness_state_digest,
        **withholding
      )
      if withholding[:withholding_override_reason].present?
        AuditLogger.record!(action: "payout.backup_withholding_overridden", auditable: payout, actor: actor,
          organization: payout.organization, metadata: { reason: withholding[:withholding_override_reason] }, request: request)
      end
      [payout, true]
    end
  rescue ActiveRecord::RecordNotUnique
    [validate_idempotent_replay!(Payout.find_by!(idempotency_key: idempotency_key)), false]
  rescue BackupWithholding::WithholdingError => e
    raise PayoutError, e.message
  end

  def validate_idempotent_replay!(payout)
    requested_amount_matches = requested_amount_cents.nil? || requested_amount_cents == payout.amount_cents
    unless payout.settlement_id == settlement.id && requested_amount_matches
      raise PayoutError, "Idempotency-Key was already used for a different payout request"
    end

    payout
  end
end
