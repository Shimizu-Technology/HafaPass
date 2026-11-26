# frozen_string_literal: true

class PayoutReconciler
  class ReconciliationError < StandardError
    attr_reader :conflict_audit_id

    def initialize(message, conflict_audit_id: nil)
      super(message)
      @conflict_audit_id = conflict_audit_id
    end
  end

  def self.call(payout:, actor:, status:, evidence:, provider_payout_id: nil, request: nil)
    raise ReconciliationError, "Administrator access is required" unless actor&.persisted? && actor.admin?
    unless (%w[paid failed reversed] + [ACCEPTED_TRANSFER]).include?(status)
      raise ReconciliationError, "Status must be paid, failed, or reversed"
    end

    normalized = normalize_evidence!(evidence)
    if status == ACCEPTED_TRANSFER
      return record_accepted_transfer!(payout: payout, actor: actor, normalized: normalized,
        provider_payout_id: provider_payout_id, request: request)
    end
    if status != "paid" && normalized["withholding_override_reason"].present?
      raise ReconciliationError, "A withholding override only applies when recording payment"
    end
    Payout.transaction do
      # Match payout reservation's organization -> event -> payout locking, so
      # releasing a reservation and reserving a new payout cannot use
      # competing snapshots, and the hold read below sees any capture on the
      # event that committed first (every capture holds the event row until
      # it commits). NO KEY UPDATE on the organization so a capture holding
      # the event can still insert its audit row (organization FK KEY SHARE).
      payout.organization.lock!("FOR NO KEY UPDATE")
      payout.event.lock!("FOR NO KEY UPDATE")
      payout.lock!
      payout.connected_account.lock! if status == "paid"
      if payout.failure_code == "provider_result_conflict"
        conflict = AuditLog.where(auditable: payout, action: "payout.provider_result_conflict").order(:id).last
        unless conflict && normalized["conflict_audit_id"] == conflict.id
          raise ReconciliationError.new("Review and acknowledge the latest provider conflict audit before recording an outcome",
            conflict_audit_id: conflict&.id)
        end
      end
      unless provider_payout_id.nil? || provider_payout_id.is_a?(String)
        raise ReconciliationError, "Transfer identifier must be text"
      end
      external_id = provider_payout_id.to_s.strip.presence || payout.provider_payout_id
      raise ReconciliationError, "Transfer identifier is too long" if external_id.to_s.length > 255
      manual_payout = %w[check manual].include?(payout.provider)
      if payout.provider == "manual"
        account_number = payout.connected_account.bank_account_number
        fields = [external_id, *normalized.values.grep(String).excluding(normalized["confirmed_at"])]
        if account_number.present? && fields.any? { |value| value.to_s.gsub(/\D/, "").include?(account_number) }
          raise ReconciliationError, "Leave full bank account numbers out of payout evidence"
        end
      end
      withholding_only = manual_payout && payout.disbursement_cents.zero? &&
        external_id == "withholding_only_#{payout.id}"
      if status == "paid" && !withholding_only && (external_id.blank? || external_id.start_with?("sim_", "manual_po_", "withholding_only_"))
        raise ReconciliationError, "A real provider or bank transfer identifier is required to record payment"
      end
      if status == "paid" && manual_payout && payout.disbursement_cents.zero? && !withholding_only
        raise ReconciliationError, "Use the withholding-only reference for a zero-net payout"
      end
      if external_id.present? && external_id != payout.provider_payout_id &&
          Payout.where(provider: payout.provider, provider_payout_id: external_id).where.not(id: payout.id).exists?
        raise ReconciliationError, payout.provider == "check" ? "That check number is already recorded" :
          "That transfer identifier is already recorded"
      end
      confirmed_at = Time.iso8601(normalized.fetch("confirmed_at"))
      if confirmed_at < payout.created_at || confirmed_at > Time.current
        raise ReconciliationError, "Confirmation time must be after the payout request and not in the future"
      end

      if payout.status == status
        previous = AuditLog.where(auditable: payout, action: "payout.reconciled").order(:id).last
        same_evidence = previous&.metadata&.fetch("reconciliation", nil) == normalized
        return payout if same_evidence && payout.provider_payout_id == external_id

        raise ReconciliationError, "This payout outcome was already recorded with different evidence"
      end
      unless payout.may_reconcile_to?(status)
        raise ReconciliationError, "Payout cannot transition from #{payout.status} to #{status}"
      end
      # Review finding 3 (e49e94d2): the provider accepted this transfer after
      # an entry guard or fence refused it, so the money left. It is never an
      # ordinary paid payout, never failed, and reversed only with the exact
      # return evidence; until then its reservation stays committed, so no
      # payout key, new or reused, can send the amount again.
      accepted = PayoutCreator.provider_accepted?(payout)
      if accepted
        raise ReconciliationError, ACCEPTED_NOT_PAID_MESSAGE if status == "paid"
        raise ReconciliationError, ACCEPTED_NOT_FAILED_MESSAGE if status == "failed"
        # A2 recheck finding 2 (7664e143): the outgoing transfer is booked
        # (CPA payouts made) by finance's acceptance record and its return
        # (payout reversals) by this reversal. A return reported before the
        # acceptance is recorded waits for it, so both postings exist once.
        unless AuditLog.where(auditable: payout, action: "payout.accepted_transfer_recorded").exists?
          raise ReconciliationError, ACCEPTED_RETURN_BEFORE_ACCEPTANCE_MESSAGE
        end

        return_evidence = verified_return!(payout, normalized, external_id)
      elsif status == "reversed" && (RETURN_KEYS.any? { |key| normalized.key?(key) } || (classified = classified_event?(payout)))
        # CodeRabbit 4704013209: a reversal says money that left came back.
        # On an event with a never-fulfilled capture it is recorded only with
        # the same exact return evidence, so an amount that left is never
        # released to be paid again on the strength of the generic
        # confirmation alone, and the P4 proof keeps treating an unverified
        # reversal as money still with the organizer
        # (hafapass_payout_return_verified). A transfer that never left is
        # recorded failed, as before. Other events keep their existing
        # reversal accounting; evidence given there is verified the same way.
        verified_return = verified_return!(payout, normalized, external_id, sent_at: payout_sent_at(payout),
          keep_identifier: payout.status_paid?,
          incomplete_message: classified || classified_event?(payout) ? CLASSIFIED_RETURN_REQUIRED_MESSAGE : RETURN_INCOMPLETE_MESSAGE)
      elsif RETURN_KEYS.any? { |key| normalized.key?(key) }
        raise ReconciliationError, "Return evidence only applies to a reversal"
      end
      if payout.status_paid? && external_id != payout.provider_payout_id
        raise ReconciliationError, "Keep the original transfer identifier when recording a reversal"
      end

      if status == "paid" && !payout.payee_matches_approval? && normalized["approved_payee_confirmed"] != true
        raise ReconciliationError, Payout::PAYEE_CHANGED_MESSAGE
      end
      if status == "paid"
        PayoutWithholdingGuard.call(payout: payout, actor: actor,
          override_reason: normalized["withholding_override_reason"], request: request)
        if payout.provider == "check"
          actual = normalized["actual_check_amount_cents"]
          raise ReconciliationError, "Enter the actual check amount in cents" unless actual
          unless actual == payout.confirmed_check_amount_cents
            raise ReconciliationError, "Actual check amount does not match the recorded net. Record a reasoned, audited check amount adjustment before reconciling."
          end
        end
        liability = payout.event.cancelled? ? EventCancellationRefunds.liability_snapshot(payout.event) :
          { outstanding_cents: 0, unresolved: false }
        queue = RefundReconciliationQueue.new(event_id: payout.event_id).entries
        if queue.any? && !payout.event.cancelled?
          raise ReconciliationError, "Resolve outstanding refund liabilities before recording this payout as paid"
        end
        # P10 holds an event with an open never-fulfilled item. A transfer
        # that already left is still recorded: its submission was authorized
        # before the hold opened, the admin confirms it was sent before the
        # hold, and the confirmed transfer time is earlier than the hold. The
        # database enforces all three for every writer (the confirmation is
        # named by FinancialIntegrity.with_payout_transfer below).
        decision = PayoutEntryGuard.blockers(payout, approvals: false,
          liability: { unresolved: liability[:unresolved] || queue.any? }).index_by { |blocker| blocker[:reason] }
        if (hold_started_at = decision.dig("hold", :started_at))
          sent_before_hold = normalized["sent_before_hold_confirmed"] == true ||
            (payout.event.cancelled? && normalized["sent_before_cancellation_confirmed"] == true)
          unless sent_before_hold && confirmed_at < hold_started_at &&
              Commerce::NeverFulfilledPayoutHold.submitted_before?(payout, hold_started_at)
            raise ReconciliationError, Commerce::NeverFulfilledPayoutHold::PAID_MESSAGE
          end
        end
        # The organizer-borne processing review (finding 1, e49e94d2): the
        # same dated prior-send exception as the hold, from when the review
        # opened. Application-enforced (the review adds no statement line).
        if (review_started_at = decision.dig("organizer_processing", :started_at))
          unless normalized["sent_before_hold_confirmed"] == true && confirmed_at < review_started_at &&
              Commerce::NeverFulfilledPayoutHold.submitted_before?(payout, review_started_at)
            raise ReconciliationError, Commerce::NeverFulfilledPayoutHold::ORGANIZER_PROCESSING_PAID_MESSAGE
          end
        end
        # A2 payout entry: a payout approved against a statement version that
        # no longer matches the current reader on an event with a classified
        # capture is not paid from that version. A transfer already submitted
        # and sent is still recorded: the admin confirms it was sent before
        # the statement changed, and the submission and the confirmed
        # transfer time precede the change (PayoutEntryGuard.paid_cutoff: the
        # restatement, or the durable time of the first changed line). When
        # a change's time cannot be proved, the confirmation alone is not
        # enough: finance records an audited disposition. The database
        # enforces the restatement case for every writer.
        entry = decision.dig("statement_changed", :entry)
        disposition = normalized.slice("stale_disposition_reason", "stale_disposition_reference")
        if disposition.any? && entry&.dig(:unproven).blank?
          raise ReconciliationError, "A stale-statement disposition only applies when the statement change cannot be dated"
        end
        if entry
          restated_at = entry[:restated_at]
          cutoff = entry[:cutoff_at]
          submitted = AuditLog.where(auditable: payout, action: "payout.submission_requested")
          submitted = submitted.where("occurred_at < ?", cutoff) if cutoff
          # The hold's own confirmation also covers a statement change no
          # earlier than the hold (the transfer time is checked against both).
          sent_confirmed = normalized["sent_before_restatement_confirmed"] == true ||
            (normalized["sent_before_hold_confirmed"] == true && hold_started_at && cutoff && hold_started_at <= cutoff)
          unless sent_confirmed && submitted.exists? && (cutoff.nil? || confirmed_at < cutoff)
            raise ReconciliationError, PayoutEntryGuard::STALE_PAID_MESSAGE
          end
          if entry[:unproven].any? && disposition.size < 2
            raise ReconciliationError, PayoutEntryGuard::DISPOSITION_MESSAGE
          end
        end
        if liability[:unresolved] || queue.any?
          unless normalized["sent_before_cancellation_confirmed"] == true && normalized["cancellation_payout_reason"].present?
            raise ReconciliationError, "Confirm this payout was already sent before the cancellation and explain why it is being recorded while buyer refunds remain unresolved"
          end
        end
        outstanding_buyer_cents = [liability[:outstanding_cents], queue.sum { |item| item[:amount_cents] }].max
        if payout.tax_information_snapshot.blank? && payout.withheld_cents.positive?
          # No W-9 was available, but the full backup withholding was reserved.
        elsif payout.tax_information_snapshot.blank?
          if normalized["approved_tax_payee_confirmed"] == true
            raise ReconciliationError, "A legacy payout has no approved W-9 payee to confirm"
          end
          unless normalized["legacy_payee_confirmed"] == true && normalized["legacy_payee_name"].present? && normalized["legacy_evidence_note"].present?
            raise ReconciliationError, "Record the actual payee, evidence note, and legacy payout confirmation"
          end
        else
          if normalized.key?("legacy_payee_name")
            raise ReconciliationError, "Legacy payee evidence is only for payouts without a W-9 snapshot"
          end
          if !payout.tax_approval_matches? && normalized["approved_tax_payee_confirmed"] != true
            raise ReconciliationError, Payout::TAX_APPROVAL_CHANGED_MESSAGE
          end
        end
      end

      hold_started_at ||= nil
      review_started_at ||= nil
      restated_at ||= nil
      entry ||= nil
      return_evidence ||= nil
      verified_return ||= nil
      shortfall = if status == "paid" && (payout.status_processing? || payout.held_from_status == "processing")
        PayeeWithholdingBalance.shortfall_for(payout)
      else
        0
      end
      before_data = payout.attributes.slice("status", "provider_payout_id", "paid_at", "under_withheld_cents")
      updates = { status: status, provider_payout_id: external_id,
        paid_at: status == "paid" ? confirmed_at : payout.paid_at,
        failure_code: status == "failed" ? "reconciled_failure" : nil,
        failure_message: status == "failed" ? normalized.fetch("reason") : nil }
      updates[:under_withheld_cents] = shortfall if status == "paid"
      # On a held event the database records paid only with this verified
      # pre-hold transfer confirmation (checked above), never from a
      # submission authorization or a timestamp alone.
      PayoutEntryGuard.with_reader do
        if status == "paid" && (hold_started_at || restated_at)
          FinancialIntegrity.with_payout_transfer(payout.id) { payout.update!(updates) }
        else
          payout.update!(updates)
        end
      end
      if shortfall.positive?
        AuditLogger.record!(action: "payout.under_withholding_carried", auditable: payout, actor: actor,
          organization: payout.organization, before_data: { under_withheld_cents: 0 },
          after_data: { under_withheld_cents: shortfall }, request: request)
      end
      if status == "paid" && payout.carried_withholding_cents.positive?
        AuditLogger.record!(action: "payout.under_withholding_collected", auditable: payout, actor: actor,
          organization: payout.organization, metadata: { amount_cents: payout.carried_withholding_cents }, request: request)
      end
      AuditLogger.record!(action: "payout.reconciled", auditable: payout, actor: actor,
        organization: payout.organization, before_data: before_data,
        after_data: payout.attributes.slice("status", "provider_payout_id", "paid_at", "under_withheld_cents"),
        metadata: { reconciliation: normalized,
          outstanding_buyer_balance_cents: status == "paid" ? outstanding_buyer_cents : nil,
          buyer_refunds_unresolved: status == "paid" ? liability[:unresolved] || queue.any? : nil,
          **(hold_started_at ? { never_fulfilled_hold_started_at: hold_started_at.utc.iso8601(6) } : {}),
          **(review_started_at ? { organizer_processing_review_started_at: review_started_at.utc.iso8601(6) } : {}),
          **(return_evidence ? { accepted_transfer_return: return_evidence } : {}),
          **(verified_return ? { verified_return: verified_return } : {}),
          # The version, not its digests: audit redaction masks long digit runs.
          **(entry ? { stale_settlement: { settlement_id: payout.settlement_id,
            settlement_version: payout.settlement.version, settlement_reader: payout.settlement.finalized_reader,
            restated_at: restated_at&.utc&.iso8601(6), cutoff_at: entry[:cutoff_at]&.utc&.iso8601(6),
            changes: stale_changes_evidence(entry[:changes]), unproven: entry[:unproven].size } } : {}) },
        request: request)
      if entry && entry[:unproven].any?
        AuditLogger.record!(action: "payout.stale_statement_disposition", auditable: payout, actor: actor,
          organization: payout.organization,
          metadata: { settlement_id: payout.settlement_id, settlement_version: payout.settlement.version,
            reason: normalized["stale_disposition_reason"], reference: normalized["stale_disposition_reference"],
            cutoff_at: entry[:cutoff_at]&.utc&.iso8601(6), confirmed_at: normalized["confirmed_at"],
            changes: stale_changes_evidence(entry[:changes]),
            unproven: entry[:unproven].map { |item| item.slice(:source_type, :source_id, :change, :reason).compact } },
          request: request)
      end
    end
    payout
  rescue PayoutWithholdingGuard::WithholdingError => e
    raise ReconciliationError, e.message
  rescue ActiveRecord::RecordInvalid => e
    raise ReconciliationError, e.record.errors.full_messages.to_sentence
  end

  # CodeRabbit 4703321670: the no-send outcome for a transfer the provider
  # accepted after the payout fence refused to record it paid
  # (PayoutCreator#record_refused_paid!). Finance confirms, with audited
  # evidence, that the money left. Nothing is submitted, the payout stays in
  # flight (its amount stays committed, so it is never sent or reserved
  # again) and it is not an ordinary paid payout: paid remains the database
  # fences' decision, and no confirmation authorizes a transfer after the
  # hold or statement change. Does not depend on the transfer time.
  ACCEPTED_TRANSFER = "accepted_transfer"
  ACCEPTED_TRANSFER_MESSAGE = "Sent by the provider after this payout's hold or statement change and recorded by " \
    "finance as an accepted transfer. Do not send it again; it is not recorded as an ordinary paid payout."

  ACCEPTED_NOT_PAID_MESSAGE = "The provider accepted this transfer after its hold or statement change. Record it as an " \
    "accepted transfer; it is never recorded as an ordinary paid payout."
  ACCEPTED_NOT_FAILED_MESSAGE = "The provider accepted this transfer, so the money left. If the bank returned it, record it " \
    "reversed with the return evidence; it is never recorded as failed."
  ACCEPTED_RETURN_BEFORE_ACCEPTANCE_MESSAGE = "Record this payout as an accepted transfer first, then record its " \
    "return. The transfer that left and the money that came back are each booked once."
  RETURN_KEYS = %w[return_reference returned_amount_cents returned_at].freeze

  # The exact return of a transfer that left: the bank's return reference,
  # the full amount that left (the disbursement), and when it came back
  # (after the transfer left and not in the future), on the same transfer
  # identifier. For an accepted transfer the transfer left when the provider
  # accepted it; for another reversal, when it was recorded paid, else
  # submitted. Anything less keeps the reservation.
  def self.verified_return!(payout, normalized, external_id, sent_at: nil, keep_identifier: true,
    incomplete_message: ACCEPTED_RETURN_REQUIRED_MESSAGE)
    accepted = sent_at.nil?
    raise ReconciliationError, incomplete_message unless RETURN_KEYS.all? { |key| normalized.key?(key) }
    if keep_identifier && external_id != payout.provider_payout_id
      raise ReconciliationError, accepted ? "Keep the provider's accepted transfer identifier" :
        "Keep the original transfer identifier when recording a reversal"
    end
    unless normalized["returned_amount_cents"] == payout.disbursement_cents
      raise ReconciliationError, "The returned amount must be the full #{payout.disbursement_cents} cents that left"
    end
    if accepted
      sent_at = AuditLog.where(auditable: payout, action: "payout.provider_result_conflict")
        .where("metadata->>'conflict_reason' = ?", PayoutCreator::PAID_REFUSED_REASON).minimum(:occurred_at)
    end
    returned_at = Time.iso8601(normalized["returned_at"])
    if sent_at.nil? || returned_at < sent_at || returned_at > Time.current
      raise ReconciliationError, accepted ? "The return time must be after the provider accepted the transfer and not in the future" :
        "The return time must be after the transfer left and not in the future"
    end

    normalized.slice(*RETURN_KEYS).merge((accepted ? "accepted_at" : "sent_at") => sent_at.utc.iso8601(6))
  end
  private_class_method :verified_return!

  ACCEPTED_RETURN_REQUIRED_MESSAGE = "An accepted transfer is reversed only with the bank's return evidence: the return " \
    "reference, the returned amount and when it was returned"
  CLASSIFIED_RETURN_REQUIRED_MESSAGE = "A payout on an event with a never-fulfilled capture is reversed only with the " \
    "bank's return evidence: the return reference, the full returned amount and when it was returned. If the transfer " \
    "never left, record it failed."
  RETURN_INCOMPLETE_MESSAGE = "Return evidence needs the return reference, the full returned amount and when it was returned"

  def self.classified_event?(payout)
    ActiveRecord::Base.connection.select_value(
      ActiveRecord::Base.sanitize_sql_array(["SELECT hafapass_event_has_classified_capture(?)", payout.event_id])
    ) == true
  end
  private_class_method :classified_event?

  # When a transfer being reversed left: its recorded paid time, else its
  # submission (or creation for a payout recorded before submissions were
  # audited).
  def self.payout_sent_at(payout)
    payout.paid_at || payout.initiated_at || payout.created_at
  end
  private_class_method :payout_sent_at

  def self.record_accepted_transfer!(payout:, actor:, normalized:, provider_payout_id:, request:)
    Payout.transaction do
      payout.organization.lock!("FOR NO KEY UPDATE")
      payout.event.lock!("FOR NO KEY UPDATE")
      payout.lock!
      conflict = AuditLog.where(auditable: payout, action: "payout.provider_result_conflict").order(:id).last
      unless payout.status_processing? && payout.failure_code == "provider_result_conflict" &&
          conflict&.metadata&.dig("conflict_reason") == PayoutCreator::PAID_REFUSED_REASON
        raise ReconciliationError, "Only a transfer the provider accepted after the payout fence refused it is recorded this way"
      end
      unless normalized["conflict_audit_id"] == conflict.id
        raise ReconciliationError.new("Review and acknowledge the latest provider conflict audit before recording an outcome",
          conflict_audit_id: conflict.id)
      end
      external_id = provider_payout_id.to_s.strip.presence || payout.provider_payout_id
      if external_id.blank? || external_id != payout.provider_payout_id
        raise ReconciliationError, "Keep the provider's accepted transfer identifier"
      end
      confirmed_at = Time.iso8601(normalized.fetch("confirmed_at"))
      if confirmed_at < payout.created_at || confirmed_at > Time.current
        raise ReconciliationError, "Confirmation time must be after the payout request and not in the future"
      end

      previous = AuditLog.where(auditable: payout, action: "payout.accepted_transfer_recorded").order(:id).last
      if previous
        return payout if previous.metadata&.fetch("reconciliation", nil) == normalized

        raise ReconciliationError, "This payout outcome was already recorded with different evidence"
      end

      hold_started_at = Commerce::NeverFulfilledPayoutHold.block_started_at(payout.event)
      entry = PayoutEntryGuard.paid_cutoff(payout)
      before_data = payout.attributes.slice("status", "provider_payout_id", "paid_at", "failure_message")
      payout.update!(failure_message: ACCEPTED_TRANSFER_MESSAGE)
      AuditLogger.record!(action: "payout.accepted_transfer_recorded", auditable: payout, actor: actor,
        organization: payout.organization, event: payout.event, before_data: before_data,
        after_data: payout.attributes.slice("status", "provider_payout_id", "paid_at", "failure_message"),
        metadata: { amount_cents: payout.amount_cents, settlement_id: payout.settlement_id, reconciliation: normalized,
          conflict_audit_id: conflict.id,
          **(hold_started_at ? { never_fulfilled_hold_started_at: hold_started_at.utc.iso8601(6) } : {}),
          **(entry ? { statement_cutoff_at: entry[:cutoff_at]&.utc&.iso8601(6) } : {}) },
        outcome: "succeeded", request: request)
    end
    payout
  end
  private_class_method :record_accepted_transfer!

  def self.normalize_evidence!(evidence)
    raise ReconciliationError, "Provider or bank confirmation evidence is required" unless evidence.is_a?(Hash)

    values = evidence.stringify_keys
    reference = values["reference"].to_s.strip
    reason = values["reason"].to_s.strip
    unless reference.present? && reference.length <= 500 && reason.present? && reason.length <= 1000
      raise ReconciliationError, "A confirmation reference and reconciliation reason are required"
    end
    [reference, reason, values["legacy_payee_name"], values["legacy_evidence_note"],
      values["cancellation_payout_reason"], values["withholding_override_reason"]].compact.each do |field|
      raise ReconciliationError, BackupWithholding::TIN_WARNING unless BackupWithholding.safe_text?(field)
    end
    timestamp = values["confirmed_at"].to_s
    raise ArgumentError unless timestamp.match?(/(?:Z|[+-]\d{2}:\d{2})\z/i)

    confirmed_at = Time.iso8601(timestamp)
    normalized = { "reference" => reference, "reason" => reason, "confirmed_at" => confirmed_at.utc.iso8601(6) }
    if values.key?("actual_check_amount_cents")
      amount = values["actual_check_amount_cents"].to_s
      raise ReconciliationError, "Actual check amount must be a nonnegative number of cents" unless amount.match?(/\A(?:0|[1-9]\d*)\z/) && amount.to_i <= 2_147_483_647

      normalized["actual_check_amount_cents"] = amount.to_i
    end
    if values.key?("conflict_audit_id")
      conflict_id = values["conflict_audit_id"].to_s
      raise ReconciliationError, "Conflict audit identifier must be a positive integer" unless conflict_id.match?(/\A[1-9]\d*\z/)

      normalized["conflict_audit_id"] = conflict_id.to_i
    end
    # Recorded in the audit evidence when a check's details on file differ
    # from the approved payee the admin wrote the check to.
    if ActiveModel::Type::Boolean.new.cast(values["approved_payee_confirmed"])
      normalized["approved_payee_confirmed"] = true
    end
    if ActiveModel::Type::Boolean.new.cast(values["approved_tax_payee_confirmed"])
      normalized["approved_tax_payee_confirmed"] = true
    end
    if ActiveModel::Type::Boolean.new.cast(values["sent_before_hold_confirmed"])
      normalized["sent_before_hold_confirmed"] = true
    end
    if ActiveModel::Type::Boolean.new.cast(values["sent_before_restatement_confirmed"])
      normalized["sent_before_restatement_confirmed"] = true
    end
    if ActiveModel::Type::Boolean.new.cast(values["sent_before_cancellation_confirmed"])
      normalized["sent_before_cancellation_confirmed"] = true
    end
    if values.key?("cancellation_payout_reason")
      cancellation_reason = values["cancellation_payout_reason"].to_s.strip
      raise ReconciliationError, "Cancellation payout reason must be 1 to 1000 characters" unless (1..1000).cover?(cancellation_reason.length)

      normalized["cancellation_payout_reason"] = cancellation_reason
    end
    if values.key?("legacy_payee_name") || values.key?("legacy_evidence_note") || values.key?("legacy_payee_confirmed")
      name = values["legacy_payee_name"].to_s.strip
      note = values["legacy_evidence_note"].to_s.strip
      raise ReconciliationError, "Legacy payee name must be 1 to 255 characters" unless (1..255).cover?(name.length)
      raise ReconciliationError, "Legacy evidence note must be 1 to 500 characters" unless (1..500).cover?(note.length)

      normalized["legacy_payee_name"] = name
      normalized["legacy_evidence_note"] = note
      normalized["legacy_payee_confirmed"] = true if ActiveModel::Type::Boolean.new.cast(values["legacy_payee_confirmed"])
    end
    %w[stale_disposition_reason stale_disposition_reference].each do |key|
      next unless values.key?(key)

      text = values[key].to_s.strip
      limit = key.end_with?("reason") ? 20..1000 : 1..255
      unless limit.cover?(text.length) && BackupWithholding.safe_text?(text)
        raise ReconciliationError, key.end_with?("reason") ? "Disposition reason must be 20 to 1000 characters" :
          "Disposition reference must be 1 to 255 characters"
      end

      normalized[key] = text
    end
    if values.key?("return_reference")
      text = values["return_reference"].to_s.strip
      unless (1..255).cover?(text.length) && BackupWithholding.safe_text?(text)
        raise ReconciliationError, "Return reference must be 1 to 255 characters"
      end

      normalized["return_reference"] = text
    end
    if values.key?("returned_amount_cents")
      amount = values["returned_amount_cents"].to_s
      raise ReconciliationError, "Returned amount must be a positive number of cents" unless amount.match?(/\A[1-9]\d*\z/) && amount.to_i <= 2_147_483_647

      normalized["returned_amount_cents"] = amount.to_i
    end
    if values.key?("returned_at")
      returned = values["returned_at"].to_s
      raise ArgumentError unless returned.match?(/(?:Z|[+-]\d{2}:\d{2})\z/i)

      normalized["returned_at"] = Time.iso8601(returned).utc.iso8601(6)
    end
    if values.key?("withholding_override_reason")
      normalized["withholding_override_reason"] = values["withholding_override_reason"].to_s.strip
    end
    normalized
  rescue ArgumentError
    raise ReconciliationError, "Confirmation time must be an ISO8601 timestamp with an offset"
  end
  private_class_method :normalize_evidence!

  def self.stale_changes_evidence(changes)
    changes.map do |change|
      { source_type: change[:source_type], source_id: change[:source_id], change: change[:change],
        at: change[:at]&.utc&.iso8601(6) }
    end
  end
  private_class_method :stale_changes_evidence
end
