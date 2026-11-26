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
#               version was restated (explicit, audited confirmation)
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

  # This release's reader, named for the database fences.
  def with_reader(&)
    FinancialIntegrity.with_settlement_reader(&)
  end

  def select_value(sql, *binds)
    ActiveRecord::Base.connection.select_value(ActiveRecord::Base.sanitize_sql_array([sql, *binds]))
  end
  private_class_method :select_value
end
