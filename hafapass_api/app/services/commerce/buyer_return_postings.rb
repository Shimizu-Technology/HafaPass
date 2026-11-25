# frozen_string_literal: true

module Commerce
  # Writes the append-only gross return postings of a never-fulfilled capture
  # (docs/design/never-fulfilled-captures.md §5.2-§5.6, A1 tranche 3).
  #
  # Callers and their locks (docs/LOCKING.md). Every caller already holds the
  # order row, so this adds no lock (the order lock below and the insert
  # trigger's re-acquire it), and nothing here makes a network call:
  #   - RefundCreator#finalize_observed_refund! (organization -> event -> order
  #     -> refund) on a succeeded refund, inbound or outbound;
  #   - StripeWebhookProcessor#process_dispute! (organization -> event ->
  #     order) on a lost dispute and on a verified late win;
  #   - NeverFulfilledClassification.classify! (event context -> order ->
  #     payment, the capture side) for movements recorded before the payment
  #     was classified, and NeverFulfilledReconcile (organization -> event ->
  #     order -> payment) for history.
  #
  # Each movement posts once (unique kind + source). A posting freezes gross,
  # applied, excess, the allocation and recognized_at = GREATEST(the movement's
  # database recording time, the capture's). Facts first posted together are
  # sequenced by (recorded_at, kind rank, source id); later facts append. A
  # reversal recomputes the surviving facts in that frozen order and appends
  # the signed delta, so earlier postings are never rewritten.
  #
  # A movement that cannot be posted from positive evidence (no recording
  # time, a different currency, a reversal whose loss cannot post) is never
  # guessed: one never_fulfilled_return_quarantined exception records it.
  # That code is a RefundSafety financial code, so it also stops outbound
  # repayment until finance resolves it.
  class BuyerReturnPostings
    QUARANTINE_CODE = "never_fulfilled_return_quarantined"
    # Before A2 adds accounting_period_closes no period is closed (§5.3, §11),
    # so every posting is recognized. A2 decides pending_correction here.
    RECOGNITION_STATE = "recognized"

    # A positive movement or a reversal, ready to post. backfill: { recorded_at:,
    # evidence: } for a fact recorded before A1 (reconcile only).
    Movement = Struct.new(:kind, :source, :gross_cents, :recorded_at, :backfill, keyword_init: true) do
      def effective_recorded_at
        recorded_at || backfill&.dig(:recorded_at)
      end

      def sort_key
        [effective_recorded_at || Time.at(0), BuyerReturnPosting::KIND_RANK.fetch(kind), source.id]
      end
    end

    class << self
      def record_refund!(refund)
        capture = capture_for(refund.payment_id)
        return unless capture && refund.succeeded?

        new(capture).post!(refund_movement(refund))
      end

      def record_dispute_loss!(dispute)
        capture = capture_for(dispute.payment_id)
        return unless capture && dispute.lost?

        new(capture).post!(loss_movement(dispute))
      end

      def record_loss_reversal!(dispute)
        capture = capture_for(dispute.payment_id)
        return unless capture && dispute.lost? && dispute.loss_reversed_at.present?

        writer = new(capture)
        writer.post!(loss_movement(dispute))
        writer.post!(reversal_movement(dispute))
      end

      # Every movement already recorded on the capture's payment that has no
      # posting yet, in the frozen tie-break order. backfills maps
      # [kind, source_type, source_id] to { recorded_at:, evidence: } for
      # facts recorded before A1 (supplied only by NeverFulfilledReconcile).
      def record_recorded_movements!(capture, backfills: {})
        writer = new(capture)
        movements = recorded_movements(capture.payment_id).map do |movement|
          movement.backfill = backfills[[movement.kind, movement.source.class.name, movement.source.id]]
          movement
        end
        movements.sort_by(&:sort_key).filter_map { |movement| writer.post!(movement) }
      end

      # Succeeded refunds, lost disputes and loss reversals of a payment, posted or not.
      def recorded_movements(payment_id)
        refunds = Refund.succeeded.where(payment_id: payment_id).order(:id).map { |refund| refund_movement(refund) }
        disputes = Dispute.lost.where(payment_id: payment_id).where("amount_cents > 0").order(:id).to_a
        refunds + disputes.map { |dispute| loss_movement(dispute) } +
          disputes.select(&:loss_reversed_at).map { |dispute| reversal_movement(dispute) }
      end

      def capture_for(payment_id)
        UnfulfilledCapture.find_by(payment_id: payment_id) if payment_id
      end

      private

      def refund_movement(refund)
        Movement.new(kind: "refund", source: refund, gross_cents: refund.amount_cents,
          recorded_at: Refund.where(id: refund.id).pick(:success_recorded_at))
      end

      def loss_movement(dispute)
        Movement.new(kind: "dispute_loss", source: dispute, gross_cents: dispute.amount_cents,
          recorded_at: Dispute.where(id: dispute.id).pick(:loss_recorded_at))
      end

      def reversal_movement(dispute)
        Movement.new(kind: "dispute_loss_reversal", source: dispute, gross_cents: -dispute.amount_cents,
          recorded_at: Dispute.where(id: dispute.id).pick(:loss_reversed_at))
      end
    end

    attr_reader :capture

    def initialize(capture)
      @capture = capture
    end

    # Returns the posting (existing or new), or nil when nothing posts.
    def post!(movement)
      raise ArgumentError, "return postings are written inside the caller's locked transaction" unless
        Order.connection.transaction_open?
      return if movement.gross_cents.zero?

      Order.where(id: capture.order_id).lock.pluck(:id)
      existing = BuyerReturnPosting.find_by(kind: movement.kind, source_type: movement.source.class.name,
        source_id: movement.source.id)
      return existing if existing

      problem = movement_problem(movement)
      attributes = movement.kind == "dispute_loss_reversal" ? reversal_attributes(movement) : forward_attributes(movement) unless problem
      problem ||= "reversed_loss_not_posted" unless attributes
      if problem
        quarantine!(movement, problem)
        return
      end

      insert!(movement, attributes)
    end

    private

    def movement_problem(movement)
      return "currency_mismatch" unless movement.source.currency.to_s.casecmp?(capture.currency)
      return if movement.recorded_at

      backfill = movement.backfill
      "recording_time_unknown" unless backfill && backfill[:recorded_at] && backfill[:evidence].present?
    end

    def ledger_facts
      postings = capture.buyer_return_postings.in_sequence.to_a
      reversed = postings.filter_map(&:reverses_posting_id).to_set
      postings.reject(&:reversal?).map do |posting|
        [posting, posting.source, !reversed.include?(posting.id)]
      end
    end

    def forward_attributes(movement)
      state = BuyerReturnLedger.for(capture).state
      step, = BuyerReturnLedger.step(state, fact_for(movement.kind, movement.source, movement.gross_cents),
        captured_cents: capture.captured_cents, components: capture.components, policy: capture.allocation_policy)
      { gross_cents: movement.gross_cents, applied_cents: step.applied_cents, excess_cents: step.excess_cents,
        components: step.components, allocation_method: step.allocation_method }
    end

    # §5.4 reversal: recompute the surviving facts in their frozen order and
    # post the signed difference from the cumulative posted totals.
    def reversal_attributes(movement)
      reversed = BuyerReturnPosting.find_by(kind: "dispute_loss", source_type: "Dispute", source_id: movement.source.id,
        never_fulfilled_capture_id: capture.id)
      return unless reversed

      survivors = ledger_facts.filter_map do |posting, source, surviving|
        fact_for(posting.kind, source, posting.gross_cents) if surviving && posting.id != reversed.id
      end
      target = BuyerReturnLedger.recompute(survivors, captured_cents: capture.captured_cents,
        components: capture.components, policy: capture.allocation_policy)
      current = BuyerReturnLedger.for(capture).state
      applied = target.applied_cents - current.applied_cents
      { gross_cents: movement.gross_cents, applied_cents: applied, excess_cents: movement.gross_cents - applied,
        components: target.components.zip(current.components).map { |goal, posted| goal - posted },
        allocation_method: "recomputed", reverses_posting: reversed }
    end

    def fact_for(kind, source, gross_cents)
      BuyerReturnLedger::Fact.new(kind: kind, gross_cents: gross_cents,
        refund_split: kind == "refund" ? refund_split(source) : nil)
    end

    # The refund's own RefundItem components, used only when they cover its
    # whole amount (item_record rule 1).
    def refund_split(refund)
      items = refund.refund_items.to_a
      return if items.empty?

      split = %i[organizer_proceeds_cents fee_cents organizer_fee_cents tax_cents]
        .map { |column| items.sum { |item| item.public_send(column) } }
      split if split.sum == refund.amount_cents
    end

    def insert!(movement, attributes)
      components = attributes.fetch(:components)
      attributes = attributes.except(:components)
      backfill = movement.backfill unless movement.recorded_at
      sequence = capture.buyer_return_postings.maximum(:sequence).to_i + 1
      posting = BuyerReturnPosting.create!(
        unfulfilled_capture: capture, sequence: sequence, kind: movement.kind, source: movement.source,
        **attributes, **BuyerReturnPosting::COMPONENTS.zip(components).to_h,
        recorded_at: movement.effective_recorded_at,
        recording_source: backfill ? "backfill" : "database",
        capture_recorded_at: capture.capture_recorded_at,
        recognized_at: [movement.effective_recorded_at, capture.capture_recorded_at].max,
        recognition_state: RECOGNITION_STATE, allocation_policy: capture.allocation_policy,
        policy_version: capture.policy_version, evidence: evidence_for(movement, backfill),
        note: note_for(movement))
      capture.buyer_return_postings.reset
      audit!(posting)
      posting
    end

    def evidence_for(movement, backfill)
      source = movement.source
      base = if source.is_a?(Refund)
        { "provider_refund_id" => source.provider_refund_id, "refund_status" => source.status,
          "business_succeeded_at" => source.succeeded_at&.utc&.iso8601(6) }
      else
        { "provider_dispute_id" => source.provider_dispute_id, "business_closed_at" => source.closed_at&.utc&.iso8601(6) }
      end
      base.merge(backfill ? backfill[:evidence].to_h.stringify_keys : {}).compact
    end

    def note_for(movement)
      return if movement.effective_recorded_at >= capture.capture_recorded_at

      "#{movement.kind.humanize} recorded before its capture; recognized at the capture's recording time"
    end

    def audit!(posting)
      order = capture.order
      AuditLogger.record!(action: "buyer_return_posting.recorded", auditable: posting,
        organization: order.event.organization, event: order.event, outcome: "succeeded",
        deduplication_key: "buyer_return_posting:#{posting.id}:recorded",
        metadata: { order_id: capture.order_id, payment_id: capture.payment_id, never_fulfilled_capture_id: capture.id,
          sequence: posting.sequence, kind: posting.kind, source_type: posting.source_type, source_id: posting.source_id,
          reverses_posting_id: posting.reverses_posting_id, gross_cents: posting.gross_cents,
          applied_cents: posting.applied_cents, excess_cents: posting.excess_cents,
          recognized_at: posting.recognized_at.utc.iso8601(6), recording_source: posting.recording_source }.compact)
    end

    def quarantine!(movement, reason)
      source = movement.source
      existing = ReconciliationException.where(payment_id: capture.payment_id, code: QUARANTINE_CODE)
        .where("details ->> 'source_type' = ? AND details ->> 'source_id' = ? AND details ->> 'kind' = ?",
          source.class.name, source.id.to_s, movement.kind).first
      existing || ReconciliationException.create!(order_id: capture.order_id, payment_id: capture.payment_id,
        code: QUARANTINE_CODE, actual_amount_cents: movement.gross_cents.abs,
        details: { reason: reason, kind: movement.kind, source_type: source.class.name, source_id: source.id,
          never_fulfilled_capture_id: capture.id })
    end
  end
end
