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

    # SQL shared by every CPA/BPT reader so the ordinary (fulfilled-sale)
    # buckets leave out exactly what this projection books. Classification is
    # by table (never_fulfilled_captures), never by the late-capture
    # exception window.
    #
    # True for an orders row with an order-scope classification.
    def self.classified_order_sql(order_id_sql = "orders.id")
      "EXISTS (SELECT 1 FROM never_fulfilled_captures nfc_order WHERE nfc_order.order_id = #{order_id_sql} " \
        "AND nfc_order.capture_scope = 'order')"
    end

    # True for a refunds or disputes row that belongs to a classified payment
    # (either scope) or to an order-scope classified order. Such a movement is
    # read from buyer_return_postings, never from RefundItems or the row's own
    # amount, and never reaches organizer custody. NULL-safe (EXISTS only).
    def self.classified_movement_sql(table)
      "(EXISTS (SELECT 1 FROM never_fulfilled_captures nfc_move WHERE nfc_move.payment_id = #{table}.payment_id) " \
        "OR #{classified_order_sql("#{table}.order_id")})"
    end

    # True for a fee_components row this projection owns: any actual
    # processing on an order-scope classified order (attributed or alerted),
    # and a component whose fee evidence names a classified payment.
    def self.classified_component_sql(table = "fee_components")
      "(#{classified_order_sql("#{table}.order_id")} OR EXISTS (SELECT 1 FROM stripe_fee_evidences nfc_fee " \
        "INNER JOIN never_fulfilled_captures nfc_fee_capture ON nfc_fee_capture.payment_id = nfc_fee.payment_id " \
        "WHERE nfc_fee.fee_component_id = #{table}.id))"
    end

    # Frozen forms for the readers (code-built SQL, no input).
    CLASSIFIED_ORDER_SQL = classified_order_sql.freeze
    CLASSIFIED_REFUND_SQL = classified_movement_sql("refunds").freeze
    CLASSIFIED_DISPUTE_SQL = classified_movement_sql("disputes").freeze
    CLASSIFIED_COMPONENT_SQL = classified_component_sql.freeze

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
    #   processing_organizer_opening_cents: organizer-borne attributed
    #     processing recognized before the period (an organizer debit already
    #     in the opening custody balance)
    #   dispute_fee_share_returned_cents: the fee and organizer-fee share of
    #     lost disputes and their late-win reversals in the period (signed),
    #     part of shares[:fee] and shares[:organizer_fee] returned; readers
    #     apply LOST_DISPUTE_FEE_SHARE (P2) to it
    #   late_capture_relates_to: order creation times of captures booked in
    #     the period whose order was created in an earlier period
    #   policies: distinct "allocation_policy policy_version" of the captures
    Totals = Struct.new(:event_id, :organization_id, :owed, :shares, :returned_gross_cents, :excess_cents,
      :excess_cumulative_cents, :processing_platform_cents, :processing_organizer_cents, :capture_ids,
      :processing_organizer_opening_cents, :dispute_fee_share_returned_cents, :late_capture_relates_to, :policies) do
      def self.zero(event_id, organization_id)
        new(event_id, organization_id, Flow.zero, SHARES.index_with { Flow.zero }, 0, 0, 0, 0, 0, [], 0, 0, [], [])
      end

      # Fee share (HåfaPass fee revenue) returned in the period that readers
      # book as fee refunds under P2. :fee_refund (default) reverses the whole
      # returned fee share; :retained keeps a lost dispute's fee share as
      # revenue (the loss is a HåfaPass cost, never an organizer debit).
      def fee_refund_cents(policy = Commerce::NeverFulfilledCapture::LOST_DISPUTE_FEE_SHARE)
        returned = fee_share_flow.returned
        policy == :retained ? returned - dispute_fee_share_returned_cents : returned
      end

      # Tax and fee share still owed at the period's close (bridge column).
      def fee_tax_closing_cents
        fee_share_flow.closing + shares[:tax].closing
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
          excess_cumulative_cents, processing_platform_cents, processing_organizer_cents,
          processing_organizer_opening_cents].any? { |cents| !cents.zero? }
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
      @alerts ||= (ambiguity_alerts + unclassified_alerts + pending_correction_alerts + processing_alerts +
        linked_adjustment_alerts)
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
          :fee_cents, :organizer_fee_cents, :tax_cents, :capture_recorded_at, :processing_bearer,
          "orders.created_at", :allocation_policy, :policy_version)
        .map { |row| CaptureRow.new(*row) }
    end

    CaptureRow = Struct.new(:id, :payment_id, :order_id, :event_id, :capture_scope, :captured_cents, :proceeds_cents,
      :fee_cents, :organizer_fee_cents, :tax_cents, :capture_recorded_at, :processing_bearer, :order_created_at,
      :allocation_policy, :policy_version) do
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
        totals.policies |= ["#{capture.allocation_policy} #{capture.policy_version}"]
        slot = capture.capture_recorded_at < period_start ? :opening : :added
        totals.owed[slot] += capture.captured_cents
        capture.shares.each { |share, cents| totals.shares[share][slot] += cents }
        if slot == :added && capture.order_created_at < period_start
          totals.late_capture_relates_to << capture.order_created_at
        end
        apply_returns!(totals, capture, returns.fetch(capture.id, []))
        platform, organizer, organizer_opening = processing.fetch(capture.id, [0, 0, 0])
        totals.processing_platform_cents += platform
        totals.processing_organizer_cents += organizer
        totals.processing_organizer_opening_cents += organizer_opening
      end.select { |_event_id, totals| totals.active? }
    end

    # Returns recognized before the period reduce the opening balance; returns
    # in the period are the period's returned flow. Signed, so a late win in
    # the period is a negative return there and earlier periods are untouched.
    def apply_returns!(totals, capture, sums)
      principal = capture.shares.keys.first
      sums.each do |before, dispute, (gross, applied, excess, proceeds, fee, organizer_fee, tax)|
        target, sign = before ? [:opening, -1] : [:returned, 1]
        totals.owed[target] += sign * applied
        { principal => proceeds, fee: fee, organizer_fee: organizer_fee, tax: tax }.each do |share, cents|
          totals.shares[share][target] += sign * cents
        end
        totals.excess_cumulative_cents += excess
        next if before

        totals.returned_gross_cents += gross
        totals.excess_cents += excess
        totals.dispute_fee_share_returned_cents += fee + organizer_fee if dispute
      end
    end

    DISPUTE_KINDS_SQL = "buyer_return_postings.kind IN ('dispute_loss', 'dispute_loss_reversal')"

    # { capture_id => [[before_period?, dispute?, [gross, applied, excess, proceeds, fee, organizer_fee, tax]], ...] }
    def posting_sums
      before_sql = ActiveRecord::Base.sanitize_sql_array(["buyer_return_postings.recognized_at < ?", period_start])
      BuyerReturnPosting.recognized
        .where(never_fulfilled_capture_id: captures.map(&:id))
        .where("buyer_return_postings.recognized_at < ?", period_end)
        .group(:never_fulfilled_capture_id, Arel.sql(before_sql), Arel.sql(DISPUTE_KINDS_SQL))
        .pluck(:never_fulfilled_capture_id, Arel.sql(before_sql), Arel.sql(DISPUTE_KINDS_SQL),
          *%w[gross_cents applied_cents excess_cents proceeds_cents fee_cents organizer_fee_cents tax_cents]
            .map { |column| Arel.sql("SUM(buyer_return_postings.#{column})") })
        .each_with_object(Hash.new { |hash, key| hash[key] = [] }) do |(capture_id, before, dispute, *sums), result|
          result[capture_id] << [before, dispute, sums.map(&:to_i)]
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
      @processing_components ||= self.class.attribute_processing(captures) + dated_deferred_processing
    end

    # Verified processing facts on a platform-borne payment-scope capture
    # that A1 keeps without a fee component (§4.6 item 8). Booked only once
    # the database has stamped their recording time (facts_recorded_at,
    # migration 20261126170000); undated rows stay alerted until
    # stripe_fee_evidence:stamp_facts dates them. Organizer-borne ones keep
    # their review hold and are never booked here.
    def deferred_processing_evidence
      @deferred_processing_evidence ||= begin
        scope_captures = captures.select { |capture| capture.capture_scope == "payment" }.index_by(&:payment_id)
        StripeFeeEvidence.where(payment_id: scope_captures.keys, fee_component_id: nil,
          last_error_code: StripeProcessingFees::PAYMENT_SCOPE_DEFERRED_CODE).where.not(evidence_digest: nil)
          .order(:payment_id).pluck(:id, :payment_id, :fee_cents, :facts_recorded_at).map do |id, payment_id, fee, recorded_at|
            { evidence_id: id, capture: scope_captures.fetch(payment_id), amount_cents: fee.to_i, recorded_at: recorded_at }
          end
      end
    end

    def dated_deferred_processing
      deferred_processing_evidence.select { |row| row[:recorded_at] && row[:capture].processing_bearer == "platform" }
        .map do |row|
          { id: nil, stripe_fee_evidence_id: row[:evidence_id], order_id: row[:capture].order_id,
            amount_cents: row[:amount_cents], recorded_at: row[:recorded_at], capture: row[:capture],
            method: "deferred_evidence" }
        end
    end

    # The one attribution rule for actual processing on orders with a
    # classified capture, shared with the operational readers
    # (Settlements::Calculator, Commerce::PlatformRevenue). `captures` respond
    # to order_id, payment_id and capture_scope. Returns one row per component
    # the classified captures own: { id:, order_id:, amount_cents:,
    # recorded_at:, capture: (nil when unattributed), method: }. A component
    # on a fulfilled order (payment scope) that is not linked to a classified
    # payment belongs to the sale and is not returned.
    def self.attribute_processing(captures)
      return [] if captures.empty?

      by_order = captures.group_by(&:order_id)
      by_payment = captures.index_by(&:payment_id)
      rows = FeeComponent.where(order_id: by_order.keys, kind: "processing", estimated: false)
        .joins("LEFT JOIN stripe_fee_evidences fee_evidence ON fee_evidence.fee_component_id = fee_components.id")
        .order(:id)
        .pluck(:id, :order_id, :amount_cents, :created_at, Arel.sql("fee_evidence.payment_id"))
      # Captured payments per order by their durable capture time, earliest
      # first. A capture from before A1 has no recording time and counts as
      # captured before every recorded one.
      captured_by_order = Payment.where(order_id: by_order.keys, status: Payment::CAPTURED_STATUSES)
        .pluck(:order_id, :id, :capture_recorded_at)
        .group_by(&:first)
        .transform_values do |list|
          list.map { |_order, payment_id, at| [payment_id, at] }
            .sort_by { |payment_id, at| [at ? 1 : 0, at.to_f, payment_id] }
        end
      rows.filter_map do |id, order_id, amount, recorded_at, evidence_payment_id|
        order_captures = by_order.fetch(order_id)
        order_scope = order_captures.any? { |capture| capture.capture_scope == "order" }
        capture = if evidence_payment_id
          by_payment[evidence_payment_id]
        elsif order_scope
          sole_capture_as_of(captured_by_order.fetch(order_id, []), recorded_at, by_payment)
        end
        next if capture.nil? && !order_scope

        { id: id, order_id: order_id, amount_cents: amount.to_i, recorded_at: recorded_at, capture: capture,
          method: evidence_payment_id ? "verified_evidence" : "sole_capture" }
      end
    end

    # The sole-capture rule as of the component's own recording time, so a
    # later capture never takes back processing an earlier period booked
    # (CodeRabbit 4703321628): the order's earliest captured payment owns an
    # unlinked component when no other payment on the order was captured at
    # or before the component was recorded. Two captures at or before it (or
    # two from before A1, which have no recording time) leave it
    # unattributed and alerted. Payments captured later cannot have produced
    # it, and their recording times are database-stamped once.
    def self.sole_capture_as_of(captured, component_recorded_at, by_payment)
      first, second = captured
      return nil if first.nil?
      return nil if second && (second.last.nil? || second.last <= component_recorded_at)

      by_payment[first.first]
    end

    # { capture_id => [platform in period, organizer in period, organizer before period] }
    def processing_by_capture
      processing_components.each_with_object(Hash.new { |hash, key| hash[key] = [0, 0, 0] }) do |component, result|
        capture = component[:capture]
        next unless capture

        recognized_at = [component[:recorded_at], capture.capture_recorded_at].max
        next if recognized_at >= period_end

        organizer = capture.processing_bearer == "organizer"
        slot = if recognized_at < period_start
          next unless organizer

          2
        else
          organizer ? 1 : 0
        end
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
      # (A1 §4.6 item 8) that cannot be booked yet: no durable recording time
      # (rows from before facts_recorded_at), or an organizer-borne snapshot
      # still under review.
      deferred = deferred_processing_evidence
        .reject { |row| row[:recorded_at] && row[:capture].processing_bearer == "platform" }.map do |row|
          capture = row[:capture]
          { code: "processing_deferred", event_id: capture.event_id, payment_id: capture.payment_id,
            processing_bearer: capture.processing_bearer, amount_cents: row[:amount_cents],
            facts_recorded_at: row[:recorded_at] }
        end
      unattributed + deferred
    end

    # Cash balance adjustments linked to classified money. No reader books
    # them as organizer custody, organizer payable or bridge
    # (ClassifiedOrganizerView); finance dispositions each one.
    def linked_adjustment_alerts
      ClassifiedOrganizerView.linked_cash_adjustments(BalanceAdjustment.where(status: [:posted, :reversed]))
        .order(:id).pluck(:id, :event_id, :organization_id, :order_id, :dispute_id, :kind, :amount_cents)
        .map do |id, event_id, organization_id, order_id, dispute_id, kind, amount|
          { code: ClassifiedOrganizerView::LINKED_ADJUSTMENT_ALERT, event_id: event_id, payment_id: nil,
            organization_id: organization_id, balance_adjustment_id: id, order_id: order_id, dispute_id: dispute_id,
            kind: kind, amount_cents: amount.to_i }
        end
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
