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
      refuse_evidence_only_acceptance!(payout)
      acknowledge_conflict!(payout, normalized) if payout.failure_code == "provider_result_conflict"
      unless provider_payout_id.nil? || provider_payout_id.is_a?(String)
        raise ReconciliationError, "Transfer identifier must be text"
      end
      external_id = provider_payout_id.to_s.strip.presence || payout.provider_payout_id
      raise ReconciliationError, "Transfer identifier is too long" if external_id.to_s.length > 255
      manual_payout = %w[check manual].include?(payout.provider)
      reject_account_number!(payout, external_id, normalized)
      withholding_only = manual_payout && payout.disbursement_cents.zero? &&
        external_id == "withholding_only_#{payout.id}"
      if status == "paid" && !withholding_only && (external_id.blank? || external_id.start_with?(*PLACEHOLDER_PREFIXES))
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
        return payout if same_evidence?(previous, normalized) && payout.provider_payout_id == external_id

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
      if normalized.key?("transfer_sent_at") && !(accepted && status == "reversed")
        raise ReconciliationError, TRANSFER_SENT_AT_MESSAGE
      end
      if accepted
        raise ReconciliationError, ACCEPTED_NOT_PAID_MESSAGE if status == "paid"
        raise ReconciliationError, ACCEPTED_NOT_FAILED_MESSAGE if status == "failed"
        # A2 recheck finding 2 (7664e143): the outgoing transfer is booked
        # (CPA payouts made) by finance's acceptance record and its return
        # (payout reversals) by this reversal. A return reported before the
        # acceptance is recorded waits for it, so both postings exist once.
        # CodeRabbit 4706251703: the durable acceptance stamp, recorded by an
        # earlier write (the database checks the row's previous value).
        raise ReconciliationError, ACCEPTED_RETURN_BEFORE_ACCEPTANCE_MESSAGE if payout.accepted_transfer_recorded_at.nil?

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
          incomplete_message: classified || classified_event?(payout) ? CLASSIFIED_RETURN_REQUIRED_MESSAGE : RETURN_INCOMPLETE_MESSAGE)
      elsif RETURN_KEYS.any? { |key| normalized.key?(key) }
        raise ReconciliationError, "Return evidence only applies to a reversal"
      end
      # CodeRabbit 4704932935: a reversal is the return of the transfer this
      # payout recorded. A paid payout, or one whose stored identifier is a
      # real transfer (a paid payout reopened by a conflicting provider
      # result keeps it), keeps that identifier: return evidence for another
      # transfer never replaces it and releases the reservation.
      if status == "reversed" && keeps_identifier?(payout) && external_id != payout.provider_payout_id
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
        metadata: { reconciliation: normalized, evidence_fingerprint: evidence_fingerprint(normalized),
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
      record_return_proof!(payout, return_evidence ? "accepted_transfer_return" : "verified_return",
        return_evidence || verified_return) if status == "reversed" && (return_evidence || verified_return)
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
  rescue ActiveRecord::RecordNotUnique => e
    raise unless e.message.include?(RETURN_REFERENCE_INDEX)

    raise ReconciliationError, RETURN_REFERENCE_USED_MESSAGE
  end

  # CodeRabbit 4705527020: one bank return reference backs at most one
  # payout's return proof, in every organization (the database's unique
  # index on its digest, so two concurrent attachments cannot both pass).
  # A retry for the same payout with the same evidence returns the recorded
  # result before any insert; another payout's reference is refused.
  RETURN_REFERENCE_INDEX = "index_payout_return_proofs_on_return_reference_digest"
  RETURN_REFERENCE_USED_MESSAGE = "That bank return reference already backs another payout's return. Use the return " \
    "reference the bank gave for this payout's own transfer."

  # The provider conflict an outcome acknowledges: the latest conflict audit,
  # by its id. CodeRabbit 4705527035: a transfer the provider accepted keeps
  # its durable marker (payouts.provider_accepted_at, written in the same
  # update as the conflict) even when the fail-open conflict audit was never
  # written. With no conflict audit to acknowledge, that marker is the
  # conflict: the outcome is recorded without an audit id, and every
  # accepted-transfer protection still applies (they read the marker).
  def self.acknowledge_conflict!(payout, normalized)
    conflict = AuditLog.where(auditable: payout, action: "payout.provider_result_conflict").order(:id).last
    if conflict
      return conflict if normalized["conflict_audit_id"] == conflict.id
    elsif payout.provider_accepted_at && !normalized.key?("conflict_audit_id")
      return nil
    end

    raise ReconciliationError.new("Review and acknowledge the latest provider conflict audit before recording an outcome",
      conflict_audit_id: conflict&.id)
  end
  private_class_method :acknowledge_conflict!

  # A full bank account number never enters payout evidence (CodeRabbit
  # 4705527049): every evidence path (outcomes, accepted transfers and
  # attached returns) checks the transfer identifier and every evidence
  # text before any audit or proof is written.
  def self.reject_account_number!(payout, external_id, normalized)
    return unless payout.provider == "manual"

    account_number = payout.connected_account.bank_account_number
    # CodeRabbit 4707205517: the parsed timestamps (by key) are times, not
    # account numbers; the identifier and every free-text field are scanned.
    fields = [external_id, *normalized.except(*TIMESTAMP_KEYS).values.grep(String)]
    return unless account_number.present? && fields.any? { |value| value.to_s.gsub(/\D/, "").include?(account_number) }

    raise ReconciliationError, "Leave full bank account numbers out of payout evidence"
  end
  private_class_method :reject_account_number!

  TIMESTAMP_KEYS = %w[confirmed_at returned_at transfer_sent_at].freeze

  # CodeRabbit 4707205504: an identical retry is recognized by a keyed
  # fingerprint of the full normalized evidence, stored beside the sanitized
  # audit copy (AuditSanitizer truncates text to 500 characters and masks
  # digit runs, so a long reason or reference never compared equal, and two
  # reasons sharing that prefix must not either). HMAC-SHA256 under a key
  # derived from secret_key_base, written in letters only (a-p) so the
  # sanitizer's digit masks never alter it, and no evidence text can be
  # recovered or confirmed from it. An audit written before the fingerprint
  # (A1's payout.reconciled) can replay only an intact exact copy.
  # Legacy text at the sanitizer's length limit, with a redaction marker,
  # or containing a URL cannot prove the original request. Anonymization
  # removes both stored forms, so later retries are refused.
  def self.evidence_fingerprint(normalized)
    key = Rails.application.key_generator.generate_key("hafapass/payout-evidence-fingerprint", 32)
    OpenSSL::HMAC.hexdigest("SHA256", key, JSON.generate(normalized.sort.to_h)).tr("0-9a-f", "a-p")
  end

  def self.same_evidence?(audit, normalized)
    metadata = audit&.metadata
    return false unless metadata.is_a?(Hash)
    return ActiveSupport::SecurityUtils.secure_compare(metadata["evidence_fingerprint"], evidence_fingerprint(normalized)) if
      metadata["evidence_fingerprint"].is_a?(String)

    recorded = metadata["reconciliation"]
    return false unless recorded.is_a?(Hash) && recorded == normalized

    recorded.values.grep(String).none? do |value|
      value.length >= AuditSanitizer::MAX_TEXT_LENGTH || value.include?(AuditSanitizer::REDACTED) || value.match?(%r{https?://}i)
    end
  end
  private_class_method :same_evidence?

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
  PLACEHOLDER_PREFIXES = %w[sim_ manual_po_ withholding_only_].freeze

  def self.keeps_identifier?(payout)
    payout.status_paid? || (payout.provider_payout_id.present? &&
      !payout.provider_payout_id.start_with?(*PLACEHOLDER_PREFIXES))
  end
  private_class_method :keeps_identifier?

  # CodeRabbit 4706251688: an acceptance with no durable marker
  # (PayoutCreator.evidence_only_acceptance?) is never acknowledged, failed,
  # paid or reversed here: it has no marker time to compare a return with,
  # and the database refuses the acknowledgement stamp without the marker.
  # It stays committed for finance to escalate. The listing offers no
  # outcome for it, and the A2 preflight counts it.
  EVIDENCE_ONLY_ACCEPTANCE_MESSAGE = "This payout's provider acceptance is shown only in its audit trail, without the " \
    "durable acceptance marker. It stays committed and is never sent again. Escalate to finance for an approved " \
    "disposition; no outcome is recorded here."

  def self.refuse_evidence_only_acceptance!(payout)
    raise ReconciliationError, EVIDENCE_ONLY_ACCEPTANCE_MESSAGE if PayoutCreator.evidence_only_acceptance?(payout)
  end
  private_class_method :refuse_evidence_only_acceptance!

  # When this payout's submission was requested (before the gateway call):
  # the earliest a transfer it sent can have left.
  def self.submission_requested_at(payout)
    AuditLog.where(auditable_type: "Payout", auditable_id: payout.id, action: "payout.submission_requested").minimum(:occurred_at)
  end
  private_class_method :submission_requested_at

  TRANSFER_SENT_AT_MESSAGE = "The bank's transfer time is given only with the return of an accepted transfer whose " \
    "paid time this release observed (the provider did not report one)"
  TRANSFER_SENT_AT_RANGE_MESSAGE = "The bank's transfer time must be no earlier than this payout's submission request and " \
    "no later than when this release observed the provider's paid result"

  # The durable proof of the exact return (PayoutReturnProof), written in
  # the reversal's own transaction (or, for a reversal already recorded,
  # with its attached evidence), named to the database as this release's.
  def self.record_return_proof!(payout, kind, evidence)
    FinancialIntegrity.with_payout_return(payout.id) do
      PayoutReturnProof.create!(payout: payout, kind: kind,
        returned_amount_cents: evidence.fetch("returned_amount_cents"),
        returned_at: Time.iso8601(evidence.fetch("returned_at")),
        sent_at: Time.iso8601(evidence.fetch("sent_at")),
        return_reference_digest: PayoutReturnProof.reference_digest(evidence.fetch("return_reference")))
    end
  end
  private_class_method :record_return_proof!

  # The exact return of a transfer that left: the bank's return reference,
  # the full amount that left (the disbursement, or the audited check amount
  # actually issued: Payout#confirmed_check_amount_cents, CodeRabbit
  # 4704932964), and when it came back (after the transfer left and not in
  # the future), on the same transfer identifier when the stored one is a
  # real transfer (keeps_identifier?). For an accepted transfer the transfer
  # left at its durable marker (provider_accepted_at). CodeRabbit
  # 4706251665: when that marker is only this release's observation of the
  # paid result (provider_accepted_basis locally_observed), finance may show
  # the bank's own, earlier transfer time (transfer_sent_at), between the
  # submission request and the observation; the return is compared with it
  # and the proof records it. A provider-reported time is not replaced. For
  # another reversal, the transfer left when it was recorded paid, else
  # submitted. Anything less keeps the reservation.
  def self.verified_return!(payout, normalized, external_id, sent_at: nil,
    incomplete_message: ACCEPTED_RETURN_REQUIRED_MESSAGE)
    accepted = sent_at.nil?
    raise ReconciliationError, incomplete_message unless RETURN_KEYS.all? { |key| normalized.key?(key) }
    # CodeRabbit 4705527043: a return is the return of a named transfer. A
    # placeholder (or no identifier) names nothing the bank could return.
    if external_id.blank? || external_id.start_with?(*PLACEHOLDER_PREFIXES)
      raise ReconciliationError, RETURN_IDENTITY_MESSAGE
    end
    if (accepted || keeps_identifier?(payout)) && external_id != payout.provider_payout_id
      raise ReconciliationError, accepted ? "Keep the provider's accepted transfer identifier" :
        "Keep the original transfer identifier when recording a reversal"
    end
    amount_left = payout.confirmed_check_amount_cents
    unless normalized["returned_amount_cents"] == amount_left
      raise ReconciliationError, "The returned amount must be the full #{amount_left} cents that left"
    end
    sent_at = payout.provider_accepted_at if accepted
    if normalized.key?("transfer_sent_at")
      raise ReconciliationError, TRANSFER_SENT_AT_MESSAGE unless accepted && payout.provider_accepted_basis == "locally_observed"

      transfer_sent_at = Time.iso8601(normalized["transfer_sent_at"])
      submitted_at = submission_requested_at(payout)
      unless submitted_at && transfer_sent_at >= submitted_at && transfer_sent_at <= sent_at
        raise ReconciliationError, TRANSFER_SENT_AT_RANGE_MESSAGE
      end

      sent_at = transfer_sent_at
    end
    returned_at = Time.iso8601(normalized["returned_at"])
    if sent_at.nil? || returned_at < sent_at || returned_at > Time.current
      raise ReconciliationError, accepted ? "The return time must be after the provider accepted the transfer and not in the future" :
        "The return time must be after the transfer left and not in the future"
    end

    evidence = normalized.slice(*RETURN_KEYS, "transfer_sent_at").merge("sent_at" => sent_at.utc.iso8601(6))
    return evidence unless accepted

    evidence.merge("accepted_at" => payout.provider_accepted_at.utc.iso8601(6),
      "accepted_basis" => payout.provider_accepted_basis)
  end
  private_class_method :verified_return!

  ACCEPTED_RETURN_REQUIRED_MESSAGE = "An accepted transfer is reversed only with the bank's return evidence: the return " \
    "reference, the returned amount and when it was returned"
  CLASSIFIED_RETURN_REQUIRED_MESSAGE = "A payout on an event with a never-fulfilled capture is reversed only with the " \
    "bank's return evidence: the return reference, the full returned amount and when it was returned. If the transfer " \
    "never left, record it failed."
  RETURN_INCOMPLETE_MESSAGE = "Return evidence needs the return reference, the full returned amount and when it was returned"
  RETURN_IDENTITY_MESSAGE = "Return evidence needs the real bank or provider transfer identifier of the transfer that came back"
  # CodeRabbit 4705527043: a reversal recorded on a placeholder (the manual
  # gateway's manual_po_, a simulation or a withholding-only reference) has
  # no authoritative transfer identifier on record, so no return can be tied
  # to it. It stays a held reversal (unknown funds) for finance to escalate.
  PLACEHOLDER_REVERSAL_MESSAGE = "This reversal was recorded without a real transfer identifier, so the bank's return " \
    "cannot be tied to it. Its event stays held; escalate to finance to establish which transfer left."

  # CodeRabbit 4707205487: what the admin outcome form needs to record a
  # reversal this reconciler accepts (Api::V1::Admin::PayoutsController),
  # or nil when no reversal can be recorded here. A reversal on an event
  # with a never-fulfilled capture, or of a transfer the provider accepted,
  # needs the bank's exact return: its reference, the full amount that left
  # (amount_cents), when it came back (no earlier than earliest_returned_at,
  # not in the future) and the transfer identifier of the money that left
  # (the stored one when keeps_transfer_id, else finance enters the real
  # one: a placeholder names nothing the bank could return). Other events
  # keep the generic reversal (return_evidence_required false). The listing
  # never offers a reversal these rules always refuse: with nothing that
  # left to return (a withholding-only or zero-net payout), an accepted
  # transfer finance has not yet acknowledged, or an accepted transfer
  # whose stored identifier is a placeholder; unavailable_reason says why.
  def self.reversal_evidence(payout, classified:, accepted:, evidence_only:)
    return nil if evidence_only || !payout.may_reconcile_to?("reversed")

    required = accepted || classified
    return { available: true, return_evidence_required: false } unless required

    stored = payout.provider_payout_id
    stored_real = stored.present? && !stored.start_with?(*PLACEHOLDER_PREFIXES)
    keeps = accepted || keeps_identifier?(payout)
    amount = payout.confirmed_check_amount_cents
    reason = if amount <= 0 then NOTHING_LEFT_TO_RETURN_MESSAGE
    elsif accepted && payout.accepted_transfer_recorded_at.nil? then ACCEPTED_RETURN_BEFORE_ACCEPTANCE_MESSAGE
    elsif keeps && !stored_real then PLACEHOLDER_REVERSAL_MESSAGE
    end
    return { available: false, return_evidence_required: true, unavailable_reason: reason } if reason

    earliest = accepted ? payout.provider_accepted_at : payout_sent_at(payout)
    { available: true, return_evidence_required: true, amount_cents: amount,
      earliest_returned_at: earliest.utc.iso8601(6), keeps_transfer_id: keeps,
      transfer_id: keeps ? stored : nil,
      # The bank's own, earlier transfer time is accepted only on the return
      # of an accepted transfer whose time is this release's observation.
      transfer_sent_at_allowed: accepted && payout.provider_accepted_basis == "locally_observed",
      transfer_sent_at_from: accepted ? submission_requested_at(payout)&.utc&.iso8601(6) : nil }
  end

  NOTHING_LEFT_TO_RETURN_MESSAGE = "No money left the bank on this withholding-only payout, so there is no bank " \
    "return to record here. Escalate to finance if the withholding itself must be undone."

  def self.classified_event?(payout)
    ActiveRecord::Base.connection.select_value(
      ActiveRecord::Base.sanitize_sql_array(["SELECT hafapass_event_has_classified_capture(?)", payout.event_id])
    ) == true
  end

  # When a transfer being reversed left: its recorded paid time, else its
  # submission (or creation for a payout recorded before submissions were
  # audited).
  def self.payout_sent_at(payout)
    payout.paid_at || payout.initiated_at || payout.created_at
  end
  private_class_method :payout_sent_at

  # CodeRabbit 4704932911: a payout already recorded reversed without the
  # exact return (an ordinary event's reversal before a capture on it was
  # classified, or history) defeats the P4 proof and keeps its event held.
  # Finance attaches the bank's exact return here: authorized (admin),
  # audited (payout.return_evidence_attached, never payout.reconciled, so
  # the CPA reversal booking keeps its original month), idempotent for the
  # same evidence, and verified the same way as a reversal's (the full
  # amount that left, a return after the transfer left, the stored real
  # transfer identifier). Nothing on the payout changes: status, amounts,
  # paid_at and its reversal's recording time stay as recorded. Without
  # this evidence the event stays held (an explicit finance hold); unknown
  # funds are never counted as returned.
  RETURN_EVIDENCE_ACTION = "payout.return_evidence_attached"

  def self.attach_return_evidence!(payout:, actor:, evidence:, provider_payout_id: nil, request: nil)
    raise ReconciliationError, "Administrator access is required" unless actor&.persisted? && actor.admin?
    unless provider_payout_id.nil? || provider_payout_id.is_a?(String)
      raise ReconciliationError, "Transfer identifier must be text"
    end

    normalized = normalize_evidence!(evidence)
    extra = normalized.keys - %w[reference reason confirmed_at transfer_sent_at] - RETURN_KEYS
    raise ReconciliationError, "Only the bank's return evidence is attached to a recorded reversal" if extra.any?

    Payout.transaction do
      payout.organization.lock!("FOR NO KEY UPDATE")
      payout.event.lock!("FOR NO KEY UPDATE")
      payout.lock!
      raise ReconciliationError, "Return evidence is attached only to a payout already recorded reversed" unless payout.status_reversed?

      refuse_evidence_only_acceptance!(payout)

      previous = AuditLog.where(auditable: payout, action: RETURN_EVIDENCE_ACTION).order(:id).last
      external_id = provider_payout_id.to_s.strip.presence || payout.provider_payout_id
      reject_account_number!(payout, external_id, normalized)
      if PayoutReturnProof.exists?(payout_id: payout.id)
        if previous && same_evidence?(previous, normalized) && previous.metadata["provider_payout_id"] == external_id
          return payout
        end

        raise ReconciliationError, previous ? "This payout's return was already recorded with different evidence" :
          "This reversal was recorded with its verified return"
      end
      confirmed_at = Time.iso8601(normalized.fetch("confirmed_at"))
      if confirmed_at < payout.created_at || confirmed_at > Time.current
        raise ReconciliationError, "Confirmation time must be after the payout request and not in the future"
      end

      # Historical evidence attaches only to the transfer the reversal
      # recorded: its stored identifier, which must be a real one.
      stored = payout.provider_payout_id
      raise ReconciliationError, PLACEHOLDER_REVERSAL_MESSAGE if stored.blank? || stored.start_with?(*PLACEHOLDER_PREFIXES)
      raise ReconciliationError, "Keep the original transfer identifier when recording a reversal" if external_id != stored

      accepted = PayoutCreator.provider_accepted?(payout)
      returned = verified_return!(payout, normalized, external_id, sent_at: accepted ? nil : payout_sent_at(payout),
        incomplete_message: RETURN_INCOMPLETE_MESSAGE)
      reversal = AuditLog.where(auditable: payout, action: %w[payout.reconciled payout.reversed]).order(:id).last
      state = payout.attributes.slice("status", "provider_payout_id", "paid_at", "amount_cents")
      AuditLogger.record!(action: RETURN_EVIDENCE_ACTION, auditable: payout, actor: actor,
        organization: payout.organization, event: payout.event, before_data: state, after_data: state,
        metadata: { reconciliation: normalized, evidence_fingerprint: evidence_fingerprint(normalized),
          provider_payout_id: external_id, (accepted ? :accepted_transfer_return : :verified_return) => returned,
          reversal_audit_id: reversal&.id, amount_left_cents: payout.confirmed_check_amount_cents },
        outcome: "succeeded", request: request)
      record_return_proof!(payout, "attached_return", returned)
    end
    payout
  rescue ActiveRecord::RecordNotUnique => e
    raise unless e.message.include?(RETURN_REFERENCE_INDEX)

    raise ReconciliationError, RETURN_REFERENCE_USED_MESSAGE
  end

  def self.record_accepted_transfer!(payout:, actor:, normalized:, provider_payout_id:, request:)
    Payout.transaction do
      payout.organization.lock!("FOR NO KEY UPDATE")
      payout.event.lock!("FOR NO KEY UPDATE")
      payout.lock!
      unless provider_payout_id.nil? || provider_payout_id.is_a?(String)
        raise ReconciliationError, "Transfer identifier must be text"
      end
      raise ReconciliationError, TRANSFER_SENT_AT_MESSAGE if normalized.key?("transfer_sent_at")

      refuse_evidence_only_acceptance!(payout)
      external_id = provider_payout_id.to_s.strip.presence || payout.provider_payout_id
      reject_account_number!(payout, external_id, normalized)
      # CodeRabbit 4705527061: an identical retry returns the recorded
      # acceptance whatever happened since (a verified return reverses the
      # payout and clears its conflict); different evidence stays refused.
      # CodeRabbit 4707205504: compared by the evidence fingerprint, never by
      # the sanitized (truncated) audit text.
      previous = AuditLog.where(auditable: payout, action: "payout.accepted_transfer_recorded").order(:id).last
      if previous || payout.accepted_transfer_recorded_at
        return payout if same_evidence?(previous, normalized) && external_id == payout.provider_payout_id

        raise ReconciliationError, "This payout outcome was already recorded with different evidence"
      end

      # CodeRabbit 4704932928: also a transfer accepted while (or before) a
      # cancellation hold held it; it stays held, committed, until returned.
      # CodeRabbit 4705527035: the durable marker, also without its audit;
      # 4706251688: only the marker (an evidence-only acceptance was refused
      # above).
      accepted = payout.provider_accepted_at.present?
      unless (payout.status_processing? || payout.status_held?) && payout.failure_code == "provider_result_conflict" && accepted
        raise ReconciliationError, "Only a transfer the provider accepted after the payout fence refused it is recorded this way"
      end
      conflict = acknowledge_conflict!(payout, normalized)
      if external_id.blank? || external_id != payout.provider_payout_id
        raise ReconciliationError, "Keep the provider's accepted transfer identifier"
      end
      confirmed_at = Time.iso8601(normalized.fetch("confirmed_at"))
      if confirmed_at < payout.created_at || confirmed_at > Time.current
        raise ReconciliationError, "Confirmation time must be after the payout request and not in the future"
      end

      hold_started_at = Commerce::NeverFulfilledPayoutHold.block_started_at(payout.event)
      entry = PayoutEntryGuard.paid_cutoff(payout)
      before_data = payout.attributes.slice("status", "provider_payout_id", "paid_at", "failure_message")
      # The database stamps the acceptance record's time once
      # (payouts_accepted_transfer_guard); a return is reversed only after it.
      # CodeRabbit 4706251703: only this audited path, naming the payout,
      # may set it (hafapass.payout_acceptance); the audit below is written
      # in the same transaction (not fail-open), so the stamp never commits
      # without it.
      FinancialIntegrity.with_payout_acceptance(payout.id) do
        payout.update!(failure_message: ACCEPTED_TRANSFER_MESSAGE, accepted_transfer_recorded_at: Time.current)
      end
      AuditLogger.record!(action: "payout.accepted_transfer_recorded", auditable: payout, actor: actor,
        organization: payout.organization, event: payout.event, before_data: before_data,
        after_data: payout.attributes.slice("status", "provider_payout_id", "paid_at", "failure_message"),
        metadata: { amount_cents: payout.amount_cents, settlement_id: payout.settlement_id, reconciliation: normalized,
          evidence_fingerprint: evidence_fingerprint(normalized), conflict_audit_id: conflict&.id,
          provider_accepted_at: payout.provider_accepted_at.utc.iso8601(6), provider_accepted_basis: payout.provider_accepted_basis,
          **(conflict ? {} : { acknowledged_marker: { provider_accepted_at: payout.provider_accepted_at.utc.iso8601(6) } }),
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
      # CodeRabbit 4706251644: compared in its canonical form, which must
      # keep a visible character (an invisible-only reference names nothing).
      if PayoutReturnProof.canonical_reference(text).empty?
        raise ReconciliationError, "Return reference must include a visible character"
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
    if values.key?("transfer_sent_at")
      sent = values["transfer_sent_at"].to_s
      raise ArgumentError unless sent.match?(/(?:Z|[+-]\d{2}:\d{2})\z/i)

      normalized["transfer_sent_at"] = Time.iso8601(sent).utc.iso8601(6)
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
