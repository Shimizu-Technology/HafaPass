# frozen_string_literal: true

class PayoutCreator
  class PayoutError < StandardError; end

  # The database's payout fences (repayment hold, restated statement,
  # custody) refuse paid for a transfer the provider accepted after the
  # event's hold or statement change began, or without its custody row.
  PAID_FENCE_REFUSAL = /Repayment fence|Payout entry fence|Payout custody fence/

  PAID_REFUSED_REASON = FinancialIntegrity::PAYOUT_PAID_REFUSED_REASON
  ACCEPTED_AFTER_FENCE_MESSAGE = "The provider accepted this transfer after its hold or statement change; it has " \
    "been sent. Do not send it again. Finance reconciles it as an accepted transfer."

  SUBMISSION_MESSAGES = {
    "hold" => Commerce::NeverFulfilledPayoutHold::MESSAGE,
    "organizer_processing" => Commerce::NeverFulfilledPayoutHold::ORGANIZER_PROCESSING_MESSAGE,
    "statement_changed" => PayoutEntryGuard::STALE_MESSAGE,
    "refund_liabilities" => "Resolve outstanding refund liabilities before paying out this event"
  }.freeze

  # The entry guards that make a provider's paid result a conflict instead
  # of an ordinary paid payout (review finding 2, e49e94d2), checked here
  # under the same organization -> event -> payout locks. The repayment hold
  # (and a restatement) stay the database fences' decision for every writer
  # (PAID_FENCE_REFUSAL, record_refused_paid!); an ordinary statement change
  # and the organizer-borne processing review have no database fence.
  PROVIDER_PAID_BLOCKERS = %w[organizer_processing statement_changed].freeze

  # Whether the provider reported this payout paid after an entry guard or
  # fence refused it (PAID_REFUSED_REASON). That money left: the payout is
  # never ordinary paid, failed, or reversed without return evidence, and
  # its reservation stays committed (PayoutReconciler).
  # The database's durable marker (payouts.provider_accepted_at, guarded by
  # payouts_accepted_transfer_guard for every writer, A2 recheck 758485ae
  # finding 1), or the conflict audit that records it.
  def self.provider_accepted?(payout)
    return true if payout.provider_accepted_at.present?

    paid_refused_audit?(payout)
  end

  # CodeRabbit 4706251688: an acceptance shown only by its conflict audit,
  # without the durable marker. No release writes one (the marker and the
  # audit are written in one transaction, the audit fail-open after the
  # marker), and the A2 preflight counts them (gate_evidence_only_zero).
  # Should one exist, it stays committed (provider_accepted? is true: never
  # paid, failed, released or resent) and PayoutReconciler records no
  # outcome for it: there is no marker time to compare a return with, so
  # finance escalates it for an approved disposition.
  def self.evidence_only_acceptance?(payout)
    payout.provider_accepted_at.nil? && paid_refused_audit?(payout)
  end

  def self.paid_refused_audit?(payout)
    AuditLog.where(auditable_type: "Payout", auditable_id: payout.id, action: "payout.provider_result_conflict")
      .where("metadata->>'conflict_reason' = ?", PAID_REFUSED_REASON).exists?
  end
  private_class_method :paid_refused_audit?

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
    # CodeRabbit 4706251665: when the provider's result reports when it paid,
    # that is the paid time; otherwise only this observation is known.
    observed_at = Time.current
    paid = result.status.to_s == "paid"
    record_submission_outcome!(payout,
      provider_payout_id: result.provider_payout_id,
      status: result.status,
      initiated_at: observed_at,
      paid_at: paid ? (result.paid_at || observed_at) : nil,
      provider_reported_paid_at: paid ? result.paid_at : nil
    )
    payout
  rescue ActiveRecord::RecordInvalid => e
    raise PayoutError, e.record.errors.full_messages.to_sentence
  end

  private

  attr_reader :settlement, :actor, :idempotency_key, :requested_amount_cents, :request, :withholding_override_reason

  # Organization -> event -> payout (docs/LOCKING.md). The event row is the
  # lock every capture holds until it commits, so the hold check below and
  # the database's submission fence see any capture that committed first,
  # and a capture that starts later waits for this authorization. NO KEY
  # UPDATE on the organization, like the other payout paths that lock an
  # event: a capture holding the event may still insert its audit row
  # (organization FK KEY SHARE). The gateway call runs after these locks.
  def submit_payout!(payout)
    payout.organization.with_lock("FOR NO KEY UPDATE") do
      payout.event.lock!("FOR NO KEY UPDATE")
      payout.with_lock do
        raise PayoutError, "Payout was held before submission" unless payout.status_pending?
        # The shared entry decision (PayoutEntryGuard.blockers): the
        # repayment hold, the organizer-borne processing review, and, A2
        # payout entry, the payout's own approved version while it is the
        # current statement, and unresolved buyer refunds.
        blocker = PayoutEntryGuard.blockers(payout, approvals: false).first
        raise PayoutError, SUBMISSION_MESSAGES.fetch(blocker[:reason]) if blocker

        PayoutWithholdingGuard.call(payout: payout, actor: actor, request: request)
        PayoutEntryGuard.with_reader do
          AuditLogger.record!(action: "payout.submission_requested", auditable: payout, actor: actor,
            organization: payout.organization, event: payout.event, outcome: "requested",
            deduplication_key: "payout:#{payout.id}:submission_requested",
            metadata: { amount_cents: payout.amount_cents, currency: payout.currency,
              settlement_id: payout.settlement_id, settlement_version: payout.settlement.version,
              settlement_reader: FinancialIntegrity::SETTLEMENT_READER }, request: request)
        end
      end
    end
    perform_provider_submission!(payout)
  rescue PayoutWithholdingGuard::WithholdingError => e
    raise PayoutError, e.message
  end

  def perform_provider_submission!(payout)
    PayoutGateway.submit(payout)
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
    AuditContext.set(fail_open: true) { record_observed_submission!(payout, **attributes) }
  end

  def record_observed_submission!(payout, **attributes)
    Payout.transaction do
      PayoutEntryGuard.with_reader { record_observed_submission_locked!(payout, **attributes) }
    end
  rescue ActiveRecord::StatementInvalid => e
    raise unless attributes[:status].to_s == "paid" && PAID_FENCE_REFUSAL.match?(e.message)

    record_refused_paid!(payout.reload, attributes, e)
  end


  # CodeRabbit 4703321670: the provider already accepted the transfer, so the
  # acceptance must not disappear with the rolled-back paid write. It is kept
  # as a conflict that finance must review: in flight, with the provider's
  # reference, never sent again (the idempotency key returns this payout).
  # Paid stays the database fences' decision; a transfer accepted after the
  # cutoff is recorded by PayoutReconciler's accepted-transfer outcome, never
  # as an ordinary paid payout.
  def record_refused_paid!(payout, attributes, error)
    Payout.transaction do
      PayoutEntryGuard.with_reader do
        payout.organization.lock!("FOR NO KEY UPDATE")
        payout.event.lock!("FOR NO KEY UPDATE")
        payout.lock!
        record_refused_paid_locked!(payout, attributes,
          refusal: error.message[/(?:Repayment|Payout entry|Payout custody) fence[^\n]*/].to_s[0, 300])
      end
    end
    payout
  end

  # Under the organization -> event -> payout locks. The provider's
  # reference, the amount and the acceptance time are kept in the row and
  # the audit; the payout stays in flight (committed).
  # CodeRabbit 4706251665: the marker is the provider's reported paid time
  # when its result carries one (basis provider_reported). Otherwise it is
  # when this release observed the paid result (locally_observed): the
  # transfer left no later than that, and possibly earlier, so it is never
  # recorded as the provider's time. A return is then compared with the
  # bank's own transfer time when finance shows it (PayoutReconciler
  # .verified_return!), between the submission request and this
  # observation.
  # CodeRabbit 4706251677: on a pending payout the move to processing
  # carries the marker, which the payout fence admits whatever the hold or
  # restatement cutoff (hafapass_payout_repayment_fence): recording money
  # that left is never refused, so the acceptance commits with its refusal.
  def record_refused_paid_locked!(payout, attributes, refusal:, blocker: nil)
    before_data = payout.attributes.slice("status", "provider_payout_id", "paid_at")
    reported = attributes[:provider_reported_paid_at]
    accepted_at = Time.zone.at((reported || attributes[:initiated_at] || Time.current).to_time.utc.floor(6))
    basis = reported ? "provider_reported" : "locally_observed"
    updates = { provider_payout_id: attributes[:provider_payout_id] || payout.provider_payout_id,
      initiated_at: attributes[:initiated_at] || payout.initiated_at, failure_code: "provider_result_conflict",
      failure_message: ACCEPTED_AFTER_FENCE_MESSAGE, provider_accepted_at: accepted_at,
      provider_accepted_basis: basis }
    updates[:status] = :processing if payout.status_pending?
    # Held before the provider answered: the transfer left, so the hold now
    # covers an in-flight (submitted) payout, whose amounts are fixed.
    updates[:held_from_status] = "processing" if payout.status_held? && payout.held_from_status == "pending"
    payout.update!(updates)
    AuditLogger.record!(action: "payout.provider_result_conflict", auditable: payout, actor: actor,
      organization: payout.organization, event: payout.event, before_data: before_data,
      after_data: payout.attributes.slice("status", "provider_payout_id", "paid_at"),
      metadata: { amount_cents: payout.amount_cents, disbursement_cents: payout.disbursement_cents,
        settlement_id: payout.settlement_id,
        failure_code: "provider_result_conflict", conflict_reason: PAID_REFUSED_REASON, refusal: refusal,
        **(blocker ? { entry_blocker: blocker[:reason], entry_blocker_started_at: blocker[:started_at]&.utc&.iso8601(6) } : {}),
        # The provider's own paid time only when it reported one.
        **(reported ? { provider_paid_at: accepted_at.utc.iso8601(6) } : { observed_paid_at: accepted_at.utc.iso8601(6) }),
        provider_accepted_basis: basis,
        provider_result: attributes.slice(:status, :provider_payout_id, :failure_code) },
      source: "provider", outcome: "unknown",
      deduplication_key: "payout:#{payout.id}:paid_refused:#{attributes[:provider_payout_id]}", request: request)
  end

  # A provider outcome is a fact about a request already sent; it is
  # recorded under this release's reader, and the database's payout fence
  # still decides processing and paid on a held or restated version.
  def record_observed_submission_locked!(payout, provider_reported_paid_at: nil, **attributes)
    # The same organization -> event -> payout order as the submission.
    payout.organization.lock!("FOR NO KEY UPDATE")
    payout.event.lock!("FOR NO KEY UPDATE")
    payout.lock!
    provider_result = attributes.dup
    refused_attributes = attributes.merge(provider_reported_paid_at: provider_reported_paid_at)
    incoming = attributes[:status].to_s
    # Review finding 2 (e49e94d2): a paid result after an ordinary statement
    # change or while the processing review is open is the provider's
    # acceptance, never an ordinary paid payout (the shared entry decision).
    if incoming == "paid" && (payout.status_pending? || payout.status_processing?) && !self.class.provider_accepted?(payout)
      blocker = PayoutEntryGuard.blockers(payout, approvals: false)
        .find { |entry| PROVIDER_PAID_BLOCKERS.include?(entry[:reason]) }
      if blocker
        return record_refused_paid_locked!(payout, refused_attributes, blocker: blocker,
          refusal: "Payout entry guard: #{blocker[:reason]} began before the provider reported the transfer paid")
      end
    end
    # CodeRabbit 4704932928: a cancellation hold can commit while the
    # gateway call runs (after the submission locks are released). The
    # provider's paid result on the held payout is the same accepted
    # transfer: kept held and committed, with its reference and paid time,
    # never failed or released without the bank's exact return. A result
    # that is not paid keeps the existing held handling below.
    if incoming == "paid" && payout.status_held? && !self.class.provider_accepted?(payout)
      held_at = AuditLog.where(auditable: payout, action: "payout.held_for_cancellation").maximum(:occurred_at)
      return record_refused_paid_locked!(payout, refused_attributes,
        blocker: { reason: "cancellation_hold", started_at: held_at },
        refusal: "Cancellation hold: the payout was held before the provider reported the transfer paid")
    end
    # An accepted transfer's money left. A later provider result never
    # downgrades it (failed releases the reservation) nor makes it ordinary
    # paid; finance reconciles it (PayoutReconciler).
    if self.class.provider_accepted?(payout) && (payout.status_processing? || payout.status_held?)
      return AuditLogger.record!(action: "payout.late_result_ignored", auditable: payout, actor: actor,
        organization: payout.organization, event: payout.event,
        before_data: payout.attributes.slice("status", "provider_payout_id", "paid_at"),
        after_data: payout.attributes.slice("status", "provider_payout_id", "paid_at"),
        metadata: { amount_cents: payout.amount_cents, settlement_id: settlement.id, accepted_transfer: true,
          provider_result: provider_result.slice(:status, :provider_payout_id, :failure_code) },
        source: "provider", outcome: "unknown",
        deduplication_key: "payout:#{payout.id}:accepted_late_result:#{Digest::SHA256.hexdigest(JSON.generate(provider_result.slice(:status, :provider_payout_id, :failure_code).stringify_keys.sort.to_h))}",
        request: request)
    end
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
      shortfall = incoming_paid && payout.status_processing? ? PayeeWithholdingBalance.shortfall_for(payout) : 0
      attributes = attributes.merge(under_withheld_cents: shortfall) if shortfall.positive?
      payout.update!(attributes)
      if shortfall.positive?
        AuditLogger.record!(action: "payout.under_withholding_carried", auditable: payout, actor: actor,
          organization: payout.organization, before_data: { under_withheld_cents: 0 },
          after_data: { under_withheld_cents: shortfall }, request: request)
      end
      if incoming_paid && payout.carried_withholding_cents.positive?
        AuditLogger.record!(action: "payout.under_withholding_collected", auditable: payout, actor: actor,
          organization: payout.organization, metadata: { amount_cents: payout.carried_withholding_cents }, request: request)
      end
    end
    AuditLogger.record!(action: action, auditable: payout, actor: actor,
      organization: payout.organization, event: payout.event, before_data: before_data,
      after_data: payout.attributes.slice("status", "provider_payout_id", "paid_at"),
      metadata: { amount_cents: payout.amount_cents, settlement_id: settlement.id,
        failure_code: attributes[:failure_code],
        provider_result: provider_result.slice(:status, :provider_payout_id, :failure_code) },
      source: "provider", outcome: submission_audit_outcome(action, attributes),
      deduplication_key: "payout:#{payout.id}:#{action}:#{Digest::SHA256.hexdigest(JSON.generate(provider_result.slice(:status, :provider_payout_id, :failure_code).stringify_keys.sort.to_h))}",
      request: request)
  end

  def reserve!
    Payout.transaction do
      # FOR NO KEY UPDATE, like the finalizer and reserves (docs/LOCKING.md):
      # serializes payout reservations and every organization money writer
      # without blocking an order lifecycle's audit FK on the organization.
      settlement.organization.lock!("FOR NO KEY UPDATE")
      settlement.event.lock!("FOR NO KEY UPDATE")
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
      raise PayoutError, Commerce::NeverFulfilledPayoutHold::MESSAGE if Commerce::NeverFulfilledPayoutHold.blocked?(settlement.event)
      if Commerce::NeverFulfilledPayoutHold.organizer_processing_held?(settlement.event)
        raise PayoutError, Commerce::NeverFulfilledPayoutHold::ORGANIZER_PROCESSING_MESSAGE
      end
      current_digest = Settlements::Calculator.call(settlement.event).attributes[:source_digest]
      if current_digest != settlement.source_digest
        raise PayoutError, "Financial activity changed; finalize a new settlement before paying out"
      end

      tax = settlement.organization.organizer_tax_information
      withholding_review = tax.nil? || tax.certified_at.nil? || tax.backup_withholding_required?
      account = settlement.organization.payout_account
      if account.nil? && withholding_review
        candidate = settlement.organization.connected_accounts.find_by(id: settlement.organization.payout_connected_account_id)
        if candidate&.payout_supported? && candidate.externally_ready? && candidate.active_payment_readiness_approval.present?
          account = candidate
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

      # This release's reader leaves never-fulfilled orders out; the database
      # lets only such a reader create a payout on an event that has one.
      payout = FinancialIntegrity.with_settlement_reader do
        settlement.payouts.create!(
          organization: settlement.organization,
          event: settlement.event,
          connected_account: account,
          provider: account.provider,
          idempotency_key: idempotency_key,
          amount_cents: amount,
          currency: settlement.currency,
          status: :pending,
          payee_snapshot: account.safe_payout_details,
          payee_approval_digest: account.provider == "manual" ? account.bank_destination_digest :
            (account.provider == "check" ? account.readiness_state_digest : nil),
          tax_information_snapshot: Payout.tax_snapshot(tax), tax_information_tin: tax&.tin,
          tax_approval_digest: account.readiness_state_digest,
          **withholding
        )
      end
      PayoutLineAllocator.record!(payout)
      AuditLogger.record!(action: "payout.created", auditable: payout, actor: actor,
        organization: payout.organization, event: payout.event, outcome: "requested",
        deduplication_key: "payout:#{payout.id}:created",
        after_data: { status: payout.status, amount_cents: payout.amount_cents, currency: payout.currency },
        metadata: { settlement_id: settlement.id }, request: request)
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

  def submission_audit_outcome(action, attributes)
    return "unknown" if %w[payout.provider_result_conflict payout.withholding_review_required].include?(action) ||
      attributes[:failure_code] == "provider_result_unknown"
    return "failed" if attributes[:status].to_s == "failed"
    return "succeeded" if attributes[:status].to_s == "paid"

    "requested"
  end
end
