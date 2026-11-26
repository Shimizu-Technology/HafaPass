# frozen_string_literal: true

module Commerce
  # Exact finance projection of classified (never-fulfilled) payments for one
  # half-open period [range.begin, range.end), normally a Guam calendar month
  # (docs/design/never-fulfilled-captures.md §5.3, §8.4, §8.5; A2).
  #
  # It reads only A1's durable rows, never RefundItems, refunds.amount_cents
  # or orders.refund_amount_cents (§6.6 item 12):
  #   - captures: never_fulfilled_captures, at capture_recorded_at. A pre-A1
  #     capture carries its backfilled time, frozen at classification;
  #   - returns: buyer_return_postings in the "recognized" state, at
  #     recognized_at = GREATEST(return recorded, capture recorded). Reversals
  #     (late wins) are signed deltas in their own period. Postings held for a
  #     closed-period correction stay out of every bucket and are alerted;
  #   - actual processing: fee_components attributed to the classified payment
  #     by its own stripe_fee_evidences link, at
  #     GREATEST(fee_components.created_at, capture_recorded_at), borne as the
  #     capture's snapshotted processing_bearer says.
  #
  # Gross owed (C - applied), excess and every share depend only on those
  # rows. The bridge is exact: gross owed equals the sum of the shares, because
  # the database pins each capture's components to its amount and each
  # posting's components to its applied amount.
  #
  # The fulfilled sale on the same order (payment A when B is a payment-scope
  # capture) never appears here: only classified payments do, and the sale's
  # own processing components stay with it.
  class ClassifiedPaymentFinance
    # Shares of what the buyer paid. A payment-scope capture is all buyer
    # principal in the first component slot (§5.4); it is never ticket
    # proceeds, so it gets its own share.
    SHARES = %i[ticket_proceeds second_capture_principal fee organizer_fee tax].freeze

    # Open items that stop a classified payment, or a payment that may be one,
    # from being projected exactly. Each is an evidence hold (A1) that only
    # evidence closes.
    AMBIGUITY_CODES = [
      NeverFulfilledClassification::QUARANTINE_CODE,
      NeverFulfilledClassification::OWNERSHIP_AMBIGUOUS_CODE,
      BuyerReturnPostings::QUARANTINE_CODE,
      NeverFulfilledReconcile::AMBIGUOUS_CODE,
      NeverFulfilledReconcile::RESTATEMENT_CODE,
      FinancialIntegrity::SALE_EFFECTS_HELD_CODE
    ].freeze

    # opening + added - returned = closing, per period.
    Flow = Struct.new(:opening, :added, :returned) do
      def self.zero
        new(0, 0, 0)
      end

      def closing
        opening + added - returned
      end

      def add!(other)
        self.opening += other.opening
        self.added += other.added
        self.returned += other.returned
        self
      end
    end

    # One event's classified money for the period.
    #   owed:   gross owed to buyers (added = captures, returned = applied returns)
    #   shares: the same flow split into SHARES
    #   returned_gross_cents: every return movement, applied and excess, signed
    #   excess_cents / excess_cumulative_cents: money returned beyond what was
    #     owed, a HåfaPass loss outside organizer custody (P4)
    #   processing_platform_cents / processing_organizer_cents: attributed
    #     actual processing recognized in the period
    Totals = Struct.new(:event_id, :organization_id, :owed, :shares, :returned_gross_cents, :excess_cents,
      :excess_cumulative_cents, :processing_platform_cents, :processing_organizer_cents, :capture_ids) do
      def self.zero(event_id, organization_id)
        new(event_id, organization_id, Flow.zero, SHARES.index_with { Flow.zero }, 0, 0, 0, 0, 0, [])
      end

      def fee_share_flow
        Flow.zero.add!(shares[:fee]).add!(shares[:organizer_fee])
      end

      # Zero by construction (see the class comment). Readers assert it.
      def bridge_difference_cents
        owed.closing - shares.values.sum(&:closing)
      end

      def active?
        [owed.opening, owed.added, owed.returned, owed.closing, returned_gross_cents, excess_cents,
          excess_cumulative_cents, processing_platform_cents, processing_organizer_cents].any? { |cents| !cents.zero? }
      end
    end

    attr_reader :range

    # payments: which classified payments count (default: live USD Stripe
    # agent captures, the custody rule every CPA/BPT reader uses).
    def initialize(range, payments: Payment.live_agent_capture)
      raise ArgumentError, "a projection needs a bounded, half-open period" if range.end.nil? || !range.exclude_end?

      @range = range
      @payments = payments
    end

    def by_event
      @by_event ||= build_totals
    end

    def for_event(event_id)
      by_event[event_id]
    end

    # Items that keep a payment out of exact projection, current at the time
    # of the read (not period-stable, like CpaMonthlyReport's
    # current_integrity_alerts). Each is { code:, payment_id:, event_id:,
    # amount_cents:, ... }.
    def alerts
      @alerts ||= (ambiguity_alerts + unclassified_alerts + pending_correction_alerts + processing_alerts)
        .sort_by { |alert| [alert[:event_id].to_i, alert[:payment_id].to_i, alert[:code]] }
    end

    private

    attr_reader :payments

    def period_start
      range.begin
    end

    def period_end
      range.end
    end

    def captures
      @captures ||= UnfulfilledCapture.joins(:order)
        .where(payment_id: payments.select(:id))
        .where("never_fulfilled_captures.capture_recorded_at < ?", period_end)
        .pluck(:id, :payment_id, :order_id, "orders.event_id", :capture_scope, :captured_cents, :proceeds_cents,
          :fee_cents, :organizer_fee_cents, :tax_cents, :capture_recorded_at, :processing_bearer)
        .map { |row| CaptureRow.new(*row) }
    end

    CaptureRow = Struct.new(:id, :payment_id, :order_id, :event_id, :capture_scope, :captured_cents, :proceeds_cents,
      :fee_cents, :organizer_fee_cents, :tax_cents, :capture_recorded_at, :processing_bearer) do
      def shares
        principal = capture_scope == "payment" ? :second_capture_principal : :ticket_proceeds
        { principal => proceeds_cents, fee: fee_cents, organizer_fee: organizer_fee_cents, tax: tax_cents }
      end
    end

    def build_totals
      return {} if captures.empty?

      organizations = Event.where(id: captures.map(&:event_id).uniq).pluck(:id, :organization_id).to_h
      returns = posting_sums
      processing = processing_by_capture
      captures.each_with_object({}) do |capture, result|
        totals = result[capture.event_id] ||= Totals.zero(capture.event_id, organizations[capture.event_id])
        totals.capture_ids << capture.id
        slot = capture.capture_recorded_at < period_start ? :opening : :added
        totals.owed[slot] += capture.captured_cents
        capture.shares.each { |share, cents| totals.shares[share][slot] += cents }
        apply_returns!(totals, capture, returns.fetch(capture.id, {}))
        platform, organizer = processing.fetch(capture.id, [0, 0])
        totals.processing_platform_cents += platform
        totals.processing_organizer_cents += organizer
      end.select { |_event_id, totals| totals.active? }
    end

    # Returns recognized before the period reduce the opening balance; returns
    # in the period are the period's returned flow. Signed, so a late win in
    # the period is a negative return there and earlier periods are untouched.
    def apply_returns!(totals, capture, sums)
      principal = capture.shares.keys.first
      sums.each do |before, (gross, applied, excess, proceeds, fee, organizer_fee, tax)|
        target, sign = before ? [:opening, -1] : [:returned, 1]
        totals.owed[target] += sign * applied
        { principal => proceeds, fee: fee, organizer_fee: organizer_fee, tax: tax }.each do |share, cents|
          totals.shares[share][target] += sign * cents
        end
        totals.excess_cumulative_cents += excess
        next if before

        totals.returned_gross_cents += gross
        totals.excess_cents += excess
      end
    end

    # { capture_id => { before_period? => [gross, applied, excess, proceeds, fee, organizer_fee, tax] } }
    def posting_sums
      before_sql = ActiveRecord::Base.sanitize_sql_array(["buyer_return_postings.recognized_at < ?", period_start])
      BuyerReturnPosting.recognized
        .where(never_fulfilled_capture_id: captures.map(&:id))
        .where("buyer_return_postings.recognized_at < ?", period_end)
        .group(:never_fulfilled_capture_id, Arel.sql(before_sql))
        .pluck(:never_fulfilled_capture_id, Arel.sql(before_sql),
          *%w[gross_cents applied_cents excess_cents proceeds_cents fee_cents organizer_fee_cents tax_cents]
            .map { |column| Arel.sql("SUM(buyer_return_postings.#{column})") })
        .each_with_object(Hash.new { |hash, key| hash[key] = {} }) do |(capture_id, before, *sums), result|
          result[capture_id][before] = sums.map(&:to_i)
        end
    end

    # Actual (non-estimated) processing components on orders with a classified
    # capture, each with the classified capture it is attributed to, or nil.
    #   - verified evidence: the component's stripe_fee_evidences row names
    #     exactly this classified payment;
    #   - sole capture: no evidence row, on an order-scope order whose only
    #     captured payment is this classified one (no other payment it could
    #     belong to; a legacy component written before evidence links).
    # A component on an order-scope order that neither rule attributes is
    # alerted. A component on a fulfilled order (payment scope) that is not
    # linked to the classified payment belongs to the sale.
    def processing_components
      @processing_components ||= begin
        by_order = captures.group_by(&:order_id)
        by_payment = captures.index_by(&:payment_id)
        rows = FeeComponent.where(order_id: by_order.keys, kind: "processing", estimated: false)
          .joins("LEFT JOIN stripe_fee_evidences fee_evidence ON fee_evidence.fee_component_id = fee_components.id")
          .order(:id)
          .pluck(:id, :order_id, :amount_cents, :created_at, Arel.sql("fee_evidence.payment_id"))
        captured_counts = Payment.where(order_id: by_order.keys, status: Payment::CAPTURED_STATUSES)
          .group(:order_id).count
        rows.filter_map do |id, order_id, amount, recorded_at, evidence_payment_id|
          order_captures = by_order.fetch(order_id)
          order_scope = order_captures.any? { |capture| capture.capture_scope == "order" }
          capture = if evidence_payment_id
            by_payment[evidence_payment_id]
          elsif order_scope && captured_counts[order_id] == 1 && order_captures.one?
            order_captures.first
          end
          next if capture.nil? && !order_scope

          { id: id, order_id: order_id, amount_cents: amount.to_i, recorded_at: recorded_at, capture: capture,
            method: evidence_payment_id ? "verified_evidence" : "sole_capture" }
        end
      end
    end

    def processing_by_capture
      processing_components.each_with_object(Hash.new { |hash, key| hash[key] = [0, 0] }) do |component, result|
        capture = component[:capture]
        next unless capture

        recognized_at = [component[:recorded_at], capture.capture_recorded_at].max
        next unless range.cover?(recognized_at)

        slot = capture.processing_bearer == "organizer" ? 1 : 0
        result[capture.id][slot] += component[:amount_cents]
      end
    end

    def processing_alerts
      events = captures.to_h { |capture| [capture.order_id, capture.event_id] }
      unattributed = processing_components.select { |component| component[:capture].nil? }.map do |component|
        { code: "processing_unattributed", event_id: events[component[:order_id]], payment_id: nil,
          order_id: component[:order_id], fee_component_id: component[:id], amount_cents: component[:amount_cents] }
      end
      # Verified facts on a payment-scope capture kept without a component
      # (A1 §4.6 item 8). They have no durable recording time yet, so they are
      # listed, never booked in a period.
      scope_captures = captures.select { |capture| capture.capture_scope == "payment" }.index_by(&:payment_id)
      deferred = StripeFeeEvidence.where(payment_id: scope_captures.keys, fee_component_id: nil,
        last_error_code: StripeProcessingFees::PAYMENT_SCOPE_DEFERRED_CODE).where.not(evidence_digest: nil)
        .order(:payment_id).pluck(:payment_id, :fee_cents).map do |payment_id, fee_cents|
          capture = scope_captures.fetch(payment_id)
          { code: "processing_deferred", event_id: capture.event_id, payment_id: payment_id,
            processing_bearer: capture.processing_bearer, amount_cents: fee_cents.to_i }
        end
      unattributed + deferred
    end

    def ambiguity_alerts
      ReconciliationException.open.where(code: AMBIGUITY_CODES, payment_id: payments.select(:id))
        .joins(:order).order(:id)
        .pluck(:code, :payment_id, "orders.event_id", :id, :actual_amount_cents).map do |code, payment_id, event_id, id, amount|
          { code: code, event_id: event_id, payment_id: payment_id, exception_id: id, amount_cents: amount.to_i }
        end
    end

    # Captured payments that may be never-fulfilled but have no classification:
    # a late-capture exception (pre-A1 history before reconcile, or a capture
    # the lifecycle quarantined) or an overlap capture the database counts
    # (hafapass_unclassified_capture). They are neither organizer custody nor
    # projected buyer liability until reconcile classifies them.
    def unclassified_alerts
      unclassified = payments.where.not(id: UnfulfilledCapture.select(:payment_id))
      late = unclassified.where(id: ReconciliationException.where(code: LateCaptureRefund::CODES).select(:payment_id))
      overlap = unclassified.where("payments.capture_recorded_at IS NOT NULL AND hafapass_unclassified_capture(payments.id)")
      [["unclassified_late_capture", late], ["unclassified_overlap_capture", overlap]].flat_map do |code, relation|
        relation.joins(:order).order(:id).pluck(:id, "orders.event_id", :amount_cents, :capture_recorded_at)
          .map do |payment_id, event_id, amount, recorded_at|
            { code: code, event_id: event_id, payment_id: payment_id, amount_cents: amount.to_i,
              capture_recorded_at: recorded_at }
          end
      end
    end

    # Returns the projection cannot see yet: postings held for a closed-period
    # correction, and recorded refunds, losses or late wins on a classified
    # payment that have no posting (an overlap writer, or a quarantined
    # movement; reconcile posts them).
    def pending_correction_alerts
      held = BuyerReturnPosting.where(recognition_state: "pending_correction", never_fulfilled_capture_id: captures.map(&:id))
        .joins(unfulfilled_capture: :order).order(:id)
        .pluck(:id, "never_fulfilled_captures.payment_id", "orders.event_id", :gross_cents, :recorded_at)
        .map do |id, payment_id, event_id, gross, recorded_at|
          { code: "return_pending_correction", event_id: event_id, payment_id: payment_id, posting_id: id,
            amount_cents: gross.to_i, recorded_at: recorded_at }
        end
      unposted = NeverFulfilledReconcile.unposted_movement_payment_ids & captures.map(&:payment_id)
      held + captures.select { |capture| unposted.include?(capture.payment_id) }.map do |capture|
        { code: "unposted_return_movement", event_id: capture.event_id, payment_id: capture.payment_id }
      end
    end
  end
end
