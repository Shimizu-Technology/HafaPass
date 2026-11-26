# frozen_string_literal: true

# A2 payout entry (docs/design/never-fulfilled-captures.md §8.10.11).
#
# A2's settlement reader adds one $0 line per classified capture, so the
# statement of every event with one changes. A payout is approved against
# one exact finalized settlement version (payouts.settlement_id). On an event
# with a classified capture, every step that can still move money checks
# that version against the current reader's digest, under the organization ->
# event -> payout locks the step already holds (docs/LOCKING.md), so a
# capture in flight is either seen or waits:
#
#   creation    PayoutCreator#reserve! (every event, unchanged rule)
#   release     PayoutHoldRelease
#   submission  PayoutCreator#submit_payout! (the authorization audit)
#   paid        PayoutReconciler: a stale payout is recorded paid only for a
#               transfer already submitted and confirmed sent before its
#               approved statement changed (paid_cutoff: the restatement or
#               the durable time of the first changed line), with an
#               audited finance disposition when that time cannot be proved
#   dispatch    before finance sends a manual transfer (the gateway only
#               records a processing placeholder), the admin list re-checks
#               the same approval and every other entry guard (blockers)
#
# The database enforces the same boundary for every writer, including an A1
# process during the overlap or after a rollback (FinancialIntegrity
# PAYOUT_ENTRY_SQL): only this release's reader may act on such an event,
# and a version missing a classified capture's line is restated from that
# capture (never before the A2 cutover). Events without a classified capture
# keep their existing rules.
module PayoutEntryGuard
  STALE_MESSAGE = "This payout's approved statement is out of date: a payment returned to a buyer changed it. " \
    "Finalize the statement again and reissue the payout for the current amount"
  STALE_PAID_MESSAGE = "This payout's approved statement is out of date. Only a transfer already submitted and sent " \
    "before the statement changed can be recorded: confirm it was sent before then, with its transfer time."
  DISPOSITION_MESSAGE = "This payout's approved statement changed at a time the records cannot prove. Record it paid only " \
    "with a finance disposition: the reason the transfer is the organizer's and the finance reference."

  module_function

  def affected?(event)
    select_value("SELECT hafapass_event_has_classified_capture(?)", event.id) == true
  end

  # When the payout's settlement version stopped accounting for the event's
  # classified captures (the database's rule), or nil.
  def restated_at(settlement)
    value = select_value("SELECT hafapass_settlement_restated_at(?)", settlement.id)
    value && ActiveRecord::Type::DateTime.new.cast(value)
  end

  # The statement a payout is approved against, under this release's
  # reader, without its payout lines: the settlement digest covers every
  # payout on the event with its status, so the payout's own reservation,
  # submission and paid recording (and any other payout's) would otherwise
  # change it. Same canonical form as Settlements::Calculator#source_digest.
  def reader_digest(items)
    canonical = items.reject { |item| item[:kind].to_s == "payout" }.map do |item|
      item.slice(:kind, :amount_cents, :currency, :source_type, :source_id, :description, :metadata)
    end
    Digest::SHA256.hexdigest(JSON.generate(canonical))
  end

  # { approved_digest:, current_digest:, restated_at: } when the payout's own
  # version is not this reader's current statement on an affected event: a
  # version an older reader finalized (no reader digest), or one whose
  # statement has changed since.
  def staleness(payout, items: nil)
    return unless affected?(payout.event)

    settlement = payout.settlement
    current = reader_digest(items || Settlements::Calculator.call(payout.event).items)
    approved = settlement.finalized_reader == FinancialIntegrity::SETTLEMENT_READER ? settlement.reader_digest : nil
    return if approved.present? && approved == current

    { approved_digest: approved, current_digest: current, restated_at: restated_at(settlement) }
  end

  def stale?(payout, items: nil)
    staleness(payout, items: items).present?
  end

  ITEM_KEYS = %i[kind amount_cents currency source_type source_id description metadata].freeze

  # When a stale payout's approved statement stopped describing the event
  # (review finding 1, 17324039), for paid recording:
  #   { cutoff_at:, restated_at:, changes: [...], unproven: [...] }
  # or nil when the payout's version is current. cutoff_at is the earliest
  # proven change: the restatement (a classified capture's missing $0 line)
  # or the durable recording time of a statement line added, removed or
  # changed since the version was finalized. A change whose time cannot be
  # shown after the finalization (a line whose source has no such time, or
  # one dated before the version it is missing from) is listed in unproven;
  # paid recording then needs an audited finance disposition, never the
  # sent-before confirmation alone (PayoutReconciler).
  def paid_cutoff(payout, items: nil)
    settlement = payout.settlement
    restated = restated_at(settlement)
    current_items = items || (affected?(payout.event) ? Settlements::Calculator.call(payout.event).items : nil)
    stale = current_items && staleness(payout, items: current_items)
    return if stale.nil? && restated.nil?

    changes = []
    unproven = []
    if stale && stale[:approved_digest].nil?
      # A version an older reader finalized cannot be compared line by line.
      # Its restatement (never before the A2 cutover) is the cutoff: before
      # it the older reader's rules governed the event.
      unproven << { reason: "older_reader_version_not_restated" } if restated.nil?
    elsif stale
      # The digest rule applies from when the event has a classified capture
      # under this reader; an earlier change kept the unchanged rules.
      affected_since = [classified_since(payout.event), FinancialCutover.recorded_at(PAYOUT_ENTRY_CUTOVER)].compact.max
      changes = statement_changes(settlement, current_items, settlement.finalized_recorded_at)
        .reject { |change| change[:at] && affected_since && change[:at] < affected_since }
      unproven = changes.reject { |change| change[:at] }
      unproven << { reason: "digest_changed_without_a_line_change" } if changes.empty? && restated.nil?
    end
    proven = changes.filter_map { |change| change[:at] }
    { cutoff_at: [restated, *proven].compact.min, restated_at: restated, changes: changes, unproven: unproven }
  end

  PAYOUT_ENTRY_CUTOVER = FinancialIntegrity::PAYOUT_ENTRY_CUTOVER

  def classified_since(event)
    UnfulfilledCapture.joins(:order).where(orders: { event_id: event.id }).minimum(:capture_recorded_at)
  end

  # Statement lines (without payout lines) added to or removed from the
  # finalized version, grouped by source, each with the source's durable
  # recording time of that change when it is after the finalization.
  def statement_changes(settlement, current_items, finalized_at)
    approved = settlement.settlement_items.where.not(kind: "payout").map do |item|
      ITEM_KEYS.index_with { |key| item.public_send(key) }
    end
    current = current_items.reject { |item| item[:kind].to_s == "payout" }
    approved_lines = approved.map { |item| canonical_line(item) }.tally
    current_lines = current.map { |item| canonical_line(item) }.tally
    added = current.select { |item| current_lines[canonical_line(item)] > approved_lines.fetch(canonical_line(item), 0) }
    removed = approved.select { |item| approved_lines[canonical_line(item)] > current_lines.fetch(canonical_line(item), 0) }
    sides = Hash.new { |hash, key| hash[key] = [] }
    added.each { |item| sides[[item[:source_type].to_s, item[:source_id]]] << :added }
    removed.each { |item| sides[[item[:source_type].to_s, item[:source_id]]] << :removed }
    sides.sort_by { |(type, id), _| [type, id.to_i] }.map do |(type, id), seen|
      change = seen.uniq.sort == [:added] ? "added" : seen.uniq.sort == [:removed] ? "removed" : "changed"
      at = finalized_at && change_time(type, id, change, finalized_at)
      { source_type: type, source_id: id, change: change, at: at }
    end
  end

  def canonical_line(item)
    JSON.generate(deep_sort(ITEM_KEYS.index_with { |key| item[key] }.deep_stringify_keys))
  end

  def deep_sort(value)
    case value
    when Hash then value.keys.map(&:to_s).sort.to_h { |key| [key, deep_sort(value[key] || value[key.to_sym])] }
    when Array then value.map { |entry| deep_sort(entry) }
    else value
    end
  end

  # The durable time a source line entered (added) or left (removed) the
  # statement, or nil when it cannot be shown. A changed line (same source,
  # different content) has no single recorded time.
  def change_time(source_type, source_id, change, finalized_at)
    classified = classification_time(source_type, source_id, finalized_at)
    time = case [source_type, change]
    when %w[RefundItem added] then RefundItem.joins(:refund).where(id: source_id).pick("refunds.success_recorded_at")
    when %w[Dispute added] then Dispute.where(id: source_id).pick(:loss_recorded_at)
    when %w[Dispute removed] then Dispute.where(id: source_id).pick(:loss_reversed_at)
    when %w[BalanceAdjustment added]
      BalanceAdjustment.where(id: source_id).pick(:created_at, :effective_at)&.compact&.max
    when %w[FeeComponent added] then FeeComponent.where(id: source_id).pick(:created_at)
    when %w[OrderItem added] then order_completion_time(OrderItem.where(id: source_id).pick(:order_id))
    when %w[UnfulfilledCapture added] then UnfulfilledCapture.where(id: source_id).pick(:capture_recorded_at)
    end
    [(time if time && time > finalized_at), classified].compact.min
  end

  # A line on an order a classified capture recorded since the version
  # changes with that classification (its database-stamped capture time).
  def classification_time(source_type, source_id, finalized_at)
    order_id = case source_type
    when "OrderItem" then OrderItem.where(id: source_id).pick(:order_id)
    when "RefundItem" then RefundItem.joins(:refund).where(id: source_id).pick("refunds.order_id")
    when "FeeComponent" then FeeComponent.where(id: source_id).pick(:order_id)
    when "Dispute" then Dispute.where(id: source_id).pick(:order_id)
    end
    order_id && UnfulfilledCapture.where(order_id: order_id).where("capture_recorded_at > ?", finalized_at)
      .minimum(:capture_recorded_at)
  end

  def order_completion_time(order_id)
    return unless order_id

    payment_id, completed_at = Order.where(id: order_id).pick(:fulfilled_by_payment_id, :completed_at)
    (payment_id && Payment.where(id: payment_id).pick(:capture_recorded_at)) || completed_at
  end

  DISPATCH_PROVIDERS = %w[manual legacy_manual check].freeze
  DISPATCH_REASONS = {
    "accepted" => "The provider accepted this transfer, so the money already left. Do not send it again. Finance " \
      "reconciles it as an accepted transfer (or escalates it when its acceptance is shown only in the audit trail).",
    "uncommitted_acceptance" => "This organization has a provider acceptance shown only in its audit trail that is " \
      "no longer committed. Do not send this transfer until finance approves a disposition.",
    "statement_changed" => "The approved statement changed after this payout was approved. Do not send this transfer. " \
      "If it was already sent, record it with its transfer time; otherwise record it failed and reissue it on the current statement.",
    "hold" => "A buyer repayment on this event is unresolved. Do not send this transfer until it is resolved.",
    "organizer_processing" => "Card processing on a payment returned to a buyer is waiting for review. Do not send this " \
      "transfer until finance books it and closes the review in Refund issues.",
    "refund_liabilities" => "Buyer refunds on this event are unresolved. Do not send this transfer until they are resolved.",
    "payee_changed" => "The organizer's payout details changed after this payout was approved. Do not send this transfer. " \
      "If it was already sent to the approved payee, record it with that confirmation; otherwise record it failed and reissue it."
  }.freeze

  # The guards every step that can move money applies (review finding 1,
  # e49e94d2), in one place: dispatch (before finance sends a manual
  # transfer), submission, the provider's outcome and paid recording read
  # this list, each the entries it enforces. Every guard applies to every
  # event; statement_changed only arises on an event with a classified
  # capture (paid_cutoff). Each entry is { reason:, started_at: } where
  # started_at, when present, is when the blocker began: a transfer
  # submitted and sent before then is still recorded (the dated prior-send
  # exception, PayoutReconciler). refund_liabilities and a changed payee
  # destination have no such date: paid recording keeps its own
  # confirmations for them (as it does for a changed tax approval, which
  # gates no entry step and so is not listed here).

  def blockers(payout, items: nil, liability: nil, approvals: true)
    event = payout.event
    found = []
    if (hold = Commerce::NeverFulfilledPayoutHold.block_started_at(event))
      found << { reason: "hold", started_at: hold }
    end
    if (review = Commerce::NeverFulfilledPayoutHold.organizer_processing_started_at(event))
      found << { reason: "organizer_processing", started_at: review }
    end
    if (entry = paid_cutoff(payout, items: items))
      found << { reason: "statement_changed", started_at: entry[:cutoff_at], entry: entry }
    end
    found << { reason: "refund_liabilities", started_at: nil } if (liability || refund_liability(event))[:unresolved]
    if approvals
      # The bank destination (or check payee) on file no longer matches
      # the one this payout was approved for.
      found << { reason: "payee_changed", started_at: nil } unless payout.payee_matches_approval?
    end
    found
  end

  # Unresolved buyer refunds on the event: a cancelled event's refund
  # balances, and the refund reconciliation queue (the admin list's figure).
  def refund_liability(event)
    snapshot = event.cancelled? ? EventCancellationRefunds.liability_snapshot(event) : { outstanding_cents: 0, unresolved: false }
    queue = RefundReconciliationQueue.new(event_id: event.id).entries
    { outstanding_cents: [snapshot[:outstanding_cents], queue.sum { |item| item[:amount_cents] }].max,
      unresolved: snapshot[:unresolved] || queue.any?, cancellation_unresolved: snapshot[:unresolved], queue: queue }
  end

  # Whether finance may still send the bank transfer (or write the check) for
  # a payout the manual gateway submitted. The gateway's result is only a
  # processing placeholder (manual_po_<id>); the money leaves when finance
  # sends it, so every entry guard is checked again here, at read time,
  # before the transfer is actionable. Nil for payouts with nothing to send.
  # The placeholder is never money: only a real transfer reference shows the
  # money left (the UI offers "send" only for a placeholder).
  # CodeRabbit 4707205465: a transfer the provider accepted (its durable
  # marker, or only its paid-refusal conflict audit) already left. It is
  # never actionable, whatever the other guards say, and says so first.
  def dispatch(payout, items: nil, liability: nil, accepted: nil, uncommitted_acceptance: nil)
    return unless payout.status_processing? && DISPATCH_PROVIDERS.include?(payout.provider)

    placeholder = placeholder?(payout.provider_payout_id)
    accepted = PayoutCreator.provider_accepted?(payout) if accepted.nil?
    if uncommitted_acceptance.nil?
      uncommitted_acceptance = PayoutCreator.uncommitted_evidence_only_acceptance?(payout.organization)
    end
    reasons = blockers(payout, items: items, liability: liability).map { |blocker| blocker[:reason] }
    reasons.unshift("uncommitted_acceptance") if uncommitted_acceptance
    reasons.unshift("accepted") if accepted
    { actionable: reasons.empty?, placeholder: placeholder,
      reasons: reasons, messages: reasons.map { |reason| DISPATCH_REASONS.fetch(reason) } }
  end

  def placeholder?(provider_payout_id)
    provider_payout_id.blank? || provider_payout_id.start_with?("manual_po_", "sim_")
  end

  # This release's reader, named for the database fences.
  def with_reader(&)
    FinancialIntegrity.with_settlement_reader(&)
  end

  def select_value(sql, *binds)
    ActiveRecord::Base.connection.select_value(ActiveRecord::Base.sanitize_sql_array([sql, *binds]))
  end
  private_class_method :select_value
end
