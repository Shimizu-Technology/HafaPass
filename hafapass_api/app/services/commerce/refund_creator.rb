# frozen_string_literal: true

require "ostruct"

module Commerce
  class RefundCreator
    class RefundError < StandardError; end
    # Stripe may prune POST identities after 24 hours. Leave a margin and
    # never create a second operation merely because reconciliation found none.
    PROVIDER_REPLAY_WINDOW = 23.hours

    def self.call(**)
      new(**).call
    end

    def self.reconcile_refund!(refund:, provider_refund:)
      new(order: refund.order, reason: refund.reason, idempotency_key: refund.idempotency_key,
        provider_refund: provider_refund).send(:finalize_refund!, refund, provider_refund)
    end

    def initialize(order:, amount_cents: nil, reason: nil, requested_by: nil, idempotency_key: nil,
      provider_refund: nil, tickets: nil, payment: nil, cash_return: nil, manual_card_return: nil)
      @order = order
      @requested_amount_cents = amount_cents&.to_i
      @reason = reason
      @requested_by = requested_by
      @idempotency_key = idempotency_key.presence || "refund:order:#{order.id}:#{SecureRandom.uuid}"
      @provider_refund = provider_refund
      @tickets = tickets.nil? ? nil : Array(tickets).compact
      @captured_payment = payment
      @cash_return = cash_return
      @manual_card_return = manual_card_return
    end

    def call
      AuditContext.set(fail_open: provider_refund.present? || AuditContext.fail_open) { execute_refund }
    end

    def execute_refund
      return record_manual_return! if cash_return || manual_card_return

      refund = reserve_refund!
      return refund unless refund.pending?
      return refund if refund.provider_refund_id.present? && !provider_refund
      return refund if !provider_refund && !provider_submission_allowed?(refund)

      response = if !provider_refund && (refund.failure_code == "provider_result_unknown" || @replayed_refund)
        recover_provider_refund(refund)
      end
      if !response && !provider_refund && !provider_submission_allowed?(refund, mark_unknown: true)
        return refund.reload
      end
      response ||= submit_provider_refund(refund)
      finalize_refund!(refund, response)
    rescue Stripe::InvalidRequestError, Stripe::CardError, StripeService::PaymentError => e
      fail_refund!(refund, "provider_error", e.message)
      raise RefundError, "Refund provider rejected the request"
    rescue Stripe::StripeError, IOError, Timeout::Error => e
      mark_unknown!(refund, "provider_result_unknown", e.message)
      raise RefundError, "Refund provider result is unknown; retry with the same idempotency key"
    end

    private :execute_refund

    private

    attr_reader :order, :requested_amount_cents, :reason, :requested_by, :idempotency_key, :provider_refund, :tickets, :captured_payment, :cash_return, :manual_card_return

    # An operator records money already returned through cash or a separate
    # card provider. This method never sends money. Keep the evidence,
    # allocations and ticket changes in one recoverable transaction.
    def record_manual_return!
      validate_cash_return!
      Order.transaction do
        refund = reserve_refund!
        next refund unless refund.pending?

        response = OpenStruct.new(id: "#{manual_card_return ? 'manual_card_return' : 'cash_return'}_#{refund.id}", status: "succeeded",
          amount: refund.amount_cents, currency: refund.currency)
        finalize_refund!(refund, response)
      end
    end

    def validate_cash_return!
      evidence_data = manual_card_return || cash_return
      unless evidence_data.is_a?(Hash) && requested_by&.persisted? && reason.present? && provider_refund.nil? &&
          !(cash_return && manual_card_return)
        raise RefundError, "Manual return requires an actor, reason, reference and returned_at timestamp"
      end
      evidence = evidence_data.stringify_keys
      reference = evidence["reference"].to_s.strip
      timestamp = evidence["returned_at"].to_s
      raise ArgumentError unless timestamp.match?(/(?:Z|[+-]\d{2}:\d{2})\z/i)

      returned_at = Time.iso8601(timestamp)
      unless reference.present? && reference.length <= 255 && returned_at <= Time.current && returned_at >= order.created_at
        raise RefundError, "Cash return reference or timestamp is invalid"
      end
      @cash_return_evidence = { "reference" => reference, "returned_at" => returned_at.utc.iso8601(6),
        "recorded_by_user_id" => requested_by.id, "cash_custodian" => "organizer" }
      @cash_return_evidence.delete("cash_custodian") if manual_card_return
    rescue ArgumentError
      raise RefundError, "Cash return timestamp must be ISO 8601 with an offset"
    end

    def reserve_refund!
      existing = order.refunds.find_by(idempotency_key: idempotency_key)
      return validate_replay!(existing) if existing

      Order.transaction do
        order.event.organization.lock!
        order.event.lock!
        order.lock!
        existing = order.refunds.find_by(idempotency_key: idempotency_key)
        next validate_replay!(existing) if existing
        unless order.completed? || order.partially_refunded? || refundable_late_capture?
          raise RefundError, "Only completed or partially refunded orders can be refunded"
        end

        ensure_financial_review_resolved! unless provider_refund

        selected_tickets = lock_selected_tickets!
        captured = order.payments.where(status: [:succeeded, :partially_refunded]).order(:id).to_a
        if captured_payment.nil? && captured.many?
          raise RefundError, "Multiple captured payments require finance reconciliation before a refund"
        end
        payment = captured_payment || captured.first
        unless payment && payment.order_id == order.id && (payment.succeeded? || payment.partially_refunded?)
          raise RefundError, "A captured payment is required for a refund"
        end
        if cash_return || manual_card_return
          if cash_return && !(payment.provider == "door_cash" && order.payment_method == "door_cash")
            raise RefundError, "Cash return recording requires an organizer-collected cash payment"
          end
          if manual_card_return && (payment.provider == "stripe" || payment.provider == "door_cash" ||
              order.payment_method != "door_card")
            raise RefundError, "Manual card return requires a captured non-Stripe door-card payment"
          end
        elsif payment.provider != "stripe" || payment.provider_payment_id.blank?
          raise RefundError, "Automated refunds are not supported for this payment provider"
        end
        if Rails.env.production? && (payment.provider_payment_id.to_s.start_with?("sim_") || payment.provider_payload["simulated"] == true)
          raise RefundError, "Simulated payments cannot be refunded in production"
        end
        payment_remaining = payment.amount_cents - payment.refunds.where(status: [:pending, :succeeded]).sum(:amount_cents)
        order_remaining = if Payment.live_or_legacy_capture.where(id: payment.id).exists?
          live_payments = order.payments.merge(Payment.live_or_legacy_capture)
          live_refunds = order.refunds.where(payment_id: live_payments.select(:id), status: [:pending, :succeeded]).sum(:amount_cents)
          [[order.total_cents, live_payments.sum(:amount_cents)].min - live_refunds, 0].max
        else
          order.refundable_cents
        end
        remaining = [order_remaining, payment_remaining].min
        amount = requested_amount_cents || selected_tickets&.sum(&:refundable_cents) || remaining
        if selected_tickets && requested_amount_cents && requested_amount_cents != selected_tickets.sum(&:refundable_cents)
          raise RefundError, "Ticket refunds must match the selected ticket value"
        end
        raise RefundError, "Refund amount must be positive" unless amount.positive?
        raise RefundError, "Refund amount exceeds refundable balance" if amount > remaining
        validate_selected_allocations!(selected_tickets) if selected_tickets

        refund = order.refunds.create!(
          payment: payment,
          requested_by: requested_by,
          provider: payment.provider,
          idempotency_key: idempotency_key,
          amount_cents: amount,
          currency: order.currency,
          status: :pending,
          reason: reason,
          provider_payload: cash_return || manual_card_return ? {
            (manual_card_return ? :manual_card_return : :cash_return) => @cash_return_evidence, manual_record: true
          } : {}
        )
        selected_tickets&.each do |ticket|
          refund.refund_tickets.create!(ticket: ticket, amount_cents: ticket.refundable_cents)
        end
        audit_refund!(refund, "requested", outcome: "requested")
        refund
      end
    rescue ActiveRecord::RecordNotUnique
      existing = order.refunds.find_by(idempotency_key: idempotency_key)
      return existing if existing

      raise RefundError, "A selected ticket already has a refund"
    rescue ActiveRecord::RecordInvalid => e
      existing = order.refunds.find_by(idempotency_key: idempotency_key)
      return existing if existing
      if e.record.is_a?(RefundTicket) && e.record.errors[:ticket_id].any?
        raise RefundError, "A selected ticket already has a refund"
      end

      raise
    end

    def provider_submission_allowed?(refund, mark_unknown: false)
      Refund.transaction do
        order.event.organization.lock!
        order.event.lock!
        order.lock!
        refund.lock!
        return false unless refund.pending? && refund.provider_refund_id.blank?

        ensure_financial_review_resolved!
        # Persist uncertainty before leaving the locks for the external call.
        # A process crash must not make an attempted operation look unsubmitted.
        if mark_unknown
          refund.update!(failure_code: "provider_result_unknown", failure_message: "Refund provider response is pending")
          audit_refund!(refund, "submission_requested", outcome: "requested")
        end
        true
      end
    end

    def ensure_financial_review_resolved!
      ignored_codes = refundable_late_capture? ? %w[late_payment_success_after_inventory_release late_payment_success_after_hold_expiry] : []
      return unless RefundSafety.finance_review_required?(order, except_codes: ignored_codes)

      raise RefundError, "Refund needs finance review; contact support before submitting another request"
    end

    # A verified late capture is money owed back, never a new fulfillment.
    # Require the released, unfulfilled reservation and the exact captured sum.
    def refundable_late_capture?
      return false unless order.cancelled? || order.expired? || order.partially_refunded?
      return false if order.completed_at.present? || order.tickets.exists?
      return false if order.inventory_holds.where.not(status: [:released, :expired]).exists? ||
        order.catalog_item_holds.where.not(status: [:released, :expired]).exists?

      captures = order.payments.where(status: [:succeeded, :partially_refunded])
      payment = captured_payment || (captures.sole if captures.count == 1)
      payment && payment.order_id == order.id && payment.provider == "stripe" &&
        %w[test live].include?(payment.provider_environment) && payment.succeeded_at.present? &&
        payment.amount_cents == order.total_cents && payment.currency == order.currency &&
        ReconciliationException.where(order: order, payment: payment,
          code: %w[late_payment_success_after_inventory_release late_payment_success_after_hold_expiry]).exists?
    end

    def lock_selected_tickets!
      return if tickets.nil?
      raise RefundError, "At least one ticket is required" if tickets.empty?

      selected = order.tickets.where(id: tickets.map(&:id)).order(:id).lock.to_a
      raise RefundError, "Ticket not found for this order" unless selected.length == tickets.map(&:id).uniq.length
      raise RefundError, "Only unused active tickets can be refunded" if selected.any? { |ticket| ticket.cancelled? || ticket.transferred? || ticket.checked_in? }
      if RefundTicket.active.where(ticket_id: selected.map(&:id)).exists?
        raise RefundError, "A selected ticket already has a refund"
      end

      selected
    end

    def validate_selected_allocations!(selected)
      selected.group_by(&:order_item).each do |item, item_tickets|
        successful = RefundItem.joins(:refund)
          .where(order_item: item, refunds: { status: Refund.statuses[:succeeded] })
        remaining = item.organizer_proceeds_cents + item.fee_cents + item.organizer_fee_cents + item.tax_cents -
          successful.sum(:amount_cents)
        raise RefundError, "Selected tickets exceed the remaining item balance" if item_tickets.sum(&:refundable_cents) > remaining
      end
    end

    def submit_provider_refund(refund)
      return provider_refund if provider_refund

      payment = refund.payment
      unless payment&.provider == "stripe" && payment.provider_payment_id.present?
        raise RefundError, "Automated refunds are not supported for this payment provider"
      end
      StripeService.refund_payment(
        payment.provider_payment_id,
        amount_cents: refund.amount_cents,
        reason: refund.reason,
        idempotency_key: refund.idempotency_key,
        payment: payment
      )
    rescue Stripe::InvalidRequestError, Stripe::CardError, StripeService::PaymentError
      raise
    rescue StandardError => e
      mark_unknown!(refund, "provider_result_unknown", e.message)
      Sentry.capture_exception(e)
      raise RefundError, "Refund provider result is unknown; retry with the same idempotency key"
    end

    def recover_provider_refund(refund)
      response = StripeService.find_refund(refund.payment.provider_payment_id, idempotency_key: refund.idempotency_key, payment: refund.payment)
      return response if response
      return if refund.created_at > PROVIDER_REPLAY_WINDOW.ago

      mark_unknown!(refund, "provider_result_unknown", "Provider replay window expired without a matching refund")
      raise RefundError, "Refund provider result is unknown; finance must reconcile before another submission"
    rescue RefundError
      raise
    rescue StandardError => e
      mark_unknown!(refund, "provider_result_unknown", e.message)
      Sentry.capture_exception(e)
      raise RefundError, "Refund provider result is unknown; provider lookup failed, reconcile before retrying"
    end

    def validate_replay!(refund)
      unless (requested_amount_cents.nil? || requested_amount_cents == refund.amount_cents) &&
          (tickets.nil? || tickets.map(&:id).sort == refund.refund_tickets.pluck(:ticket_id).sort) &&
          (!cash_return || (refund.provider == "door_cash" && refund.provider_payload["cash_return"] == @cash_return_evidence)) &&
          (!manual_card_return || (refund.provider != "stripe" && refund.provider != "door_cash" &&
            refund.provider_payload["manual_card_return"] == @cash_return_evidence))
        raise RefundError, "Idempotency-Key was already used for a different refund request"
      end
      @replayed_refund = true
      refund
    end

    def fail_refund!(refund, code, message, status: :failed)
      return unless refund

      refund.with_lock do
        return refund if refund.succeeded?

        refund.refund_tickets.update_all(released_at: Time.current)
        refund.update!(status: status, failed_at: Time.current, failure_code: code, failure_message: message)
        audit_refund!(refund, "failed", outcome: "failed", source: "provider")
      end
    end

    def mark_unknown!(refund, code, message)
      return unless refund

      refund.with_lock do
        return refund unless refund.pending?

        refund.update!(failure_code: code, failure_message: message)
        audit_refund!(refund, "unknown", outcome: "unknown", source: "provider")
      end
    end

    def audit_refund!(refund, action, outcome:, source: nil, observation: nil)
      options = {}
      options[:source] = source || "provider" if source || provider_refund
      observed = {}
      { id: :id, status: :status, amount_cents: :amount, currency: :currency }.each do |key, attribute|
        observed[key] = observation.public_send(attribute) if observation&.respond_to?(attribute)
      end
      snapshot = refund.attributes.slice("status", "provider_refund_id", "failure_code")
      fingerprint = Digest::SHA256.hexdigest(JSON.generate([snapshot, observed]))
      AuditLogger.record!(action: "refund.#{action}", auditable: refund, actor: requested_by,
        organization: refund.order.event.organization, event: refund.order.event,
        outcome: outcome, deduplication_key: "refund:#{refund.id}:#{action}:#{fingerprint}",
        after_data: snapshot,
        metadata: { order_id: refund.order_id, payment_id: refund.payment_id,
          amount_cents: refund.amount_cents, currency: refund.currency,
          provider_observation: observed,
          manual_record: cash_return.present? || manual_card_return.present? }, **options)
    end

    def finalize_refund!(refund, provider_refund)
      AuditContext.set(fail_open: !(cash_return || manual_card_return)) do
        finalize_observed_refund!(refund, provider_refund)
      end
    end

    def finalize_observed_refund!(refund, provider_refund)
      full_refund = false
      validation_error = nil
      provider_status = provider_refund.respond_to?(:status) ? provider_refund.status.to_s : ""

      Refund.transaction do
        refund.order.event.organization.lock!
        refund.order.event.lock!
        refund.order.lock!
        refund.lock!
        # A webhook can finish this operation while the original POST is still
        # in flight. Re-read every terminal state under the same locks before
        # touching its released ticket reservations or financial allocations.
        if refund.succeeded? || refund.failed? || refund.cancelled?
          contradictory = (refund.succeeded? && %w[failed canceled cancelled].include?(provider_status)) ||
            (!refund.succeeded? && provider_status == "succeeded")
          if contradictory
            ReconciliationException.create!(order: refund.order, payment: refund.payment,
              code: "refund_terminal_status_conflict")
            audit_refund!(refund, "provider_result_conflict", outcome: "unknown", source: "provider", observation: provider_refund)
          end
          return refund
        end

        unless %w[succeeded pending requires_action failed canceled cancelled].include?(provider_status) && provider_refund.respond_to?(:id) && provider_refund.id.present?
          mark_unknown!(refund, "provider_result_unknown", "Refund response is incomplete")
          validation_error = "Refund provider result is unknown; reconcile before retrying"
          next
        end

        if (provider_refund.respond_to?(:amount) && provider_refund.amount.to_i != refund.amount_cents) ||
            (provider_refund.respond_to?(:currency) && provider_refund.currency.to_s.downcase != refund.currency)
          mark_unknown!(refund, "provider_result_mismatch", "Refund response does not match the reservation")
          ReconciliationException.create!(order: refund.order, payment: refund.payment, code: "refund_operation_mismatch")
          validation_error = "Refund provider result does not match the reservation; reconcile before retrying"
          next
        end

        refund.update!(
          provider_refund_id: provider_refund.id,
          provider_payload: refund.provider_payload.merge("status" => provider_status),
          failure_code: nil,
          failure_message: nil,
          status: :pending
        )
        if %w[failed canceled cancelled].include?(provider_status)
          fail_refund!(refund, "provider_#{provider_status}", "Provider refund #{provider_status}",
            status: provider_status == "failed" ? :failed : :cancelled)
          return refund.reload
        end
        unless provider_status == "succeeded"
          audit_refund!(refund, "pending", outcome: "requested", source: "provider", observation: provider_refund)
          return refund.reload
        end

        refund.update!(status: :succeeded, succeeded_at: Time.current, failure_code: nil, failure_message: nil)
        allocate_items!(refund)
        record_promoter_commission_reversal!(refund)

        succeeded_refunds = refund.order.refunds.succeeded
        if Payment.live_or_legacy_capture.where(id: refund.payment_id).exists?
          succeeded_refunds = succeeded_refunds.where(payment_id: refund.order.payments.merge(Payment.live_or_legacy_capture).select(:id))
        end
        succeeded_total = succeeded_refunds.sum(:amount_cents)
        full_refund = succeeded_total >= refund.order.total_cents
        refund.order.update!(
          status: full_refund ? :refunded : :partially_refunded,
          refund_amount_cents: succeeded_total,
          refund_reason: reason,
          refunded_at: Time.current,
          stripe_refund_id: refund.provider == "stripe" ? provider_refund.id : refund.order.stripe_refund_id
        )
        update_payment_refund_status!(refund.payment, refund.payment.refunds.succeeded.sum(:amount_cents))
        resolve_repaid_late_capture!(refund)
        audit_refund!(refund, "succeeded", outcome: "succeeded",
          source: cash_return || manual_card_return ? nil : "provider", observation: provider_refund)
        AuditLogger.record!(action: "order.#{full_refund ? 'refunded' : 'partially_refunded'}",
          auditable: refund.order, actor: requested_by, organization: refund.order.event.organization,
          event: refund.order.event, outcome: "succeeded",
          deduplication_key: "order:#{refund.order_id}:refund:#{refund.id}",
          after_data: { status: refund.order.status, refund_amount_cents: succeeded_total },
          metadata: { refund_id: refund.id, amount_cents: refund.amount_cents },
          **(cash_return || manual_card_return ? {} : { source: "provider" }))
        StripeProcessingFees.require_adjustment_review!(refund.payment, reference: "refund:#{refund.provider_refund_id}")
        if full_refund
          release_fully_refunded_inventory!(refund)
        elsif refund.refund_tickets.any?
          release_refunded_tickets!(refund)
        end
        unless refund.provider == "door_cash" && refund.provider_payload["manual_record"] == true
          EmailService.send_refund_notification_async(refund.order, refund: refund)
        end
      end

      raise RefundError, validation_error if validation_error

      refund.order.event.notify_waitlist_if_available if full_refund || refund.refund_tickets.any?
      refund.reload
    end

    def allocate_items!(refund)
      return allocate_selected_tickets!(refund) if refund.refund_tickets.any?

      remaining = refund.amount_cents
      refund.order.order_items.order(:id).each do |item|
        successful_allocations = RefundItem.joins(:refund)
          .where(order_item: item, refunds: { status: Refund.statuses[:succeeded] })
        if Payment.live_or_legacy_capture.where(id: refund.payment_id).exists?
          successful_allocations = successful_allocations.where(
            refunds: { payment_id: refund.order.payments.merge(Payment.live_or_legacy_capture).select(:id) })
        end
        organizer_remaining = item.organizer_proceeds_cents - successful_allocations.sum(:organizer_proceeds_cents)
        fee_remaining = item.fee_cents - successful_allocations.sum(:fee_cents)
        organizer_fee_remaining = item.organizer_fee_cents - successful_allocations.sum(:organizer_fee_cents)
        tax_remaining = item.tax_cents - successful_allocations.sum(:tax_cents)
        available = organizer_remaining + fee_remaining + organizer_fee_remaining + tax_remaining
        allocation = [remaining, available].min
        next if allocation.zero?

        components = MoneyAllocator.call(allocation,
          [organizer_remaining, fee_remaining, organizer_fee_remaining, tax_remaining])
        refund.refund_items.create!(
          order_item: item,
          amount_cents: allocation,
          organizer_proceeds_cents: components[0],
          fee_cents: components[1],
          organizer_fee_cents: components[2],
          tax_cents: components[3],
          quantity: 0
        )
        remaining -= allocation
        break if remaining.zero?
      end

      raise RefundError, "Refund could not be allocated to order items" unless remaining.zero?
    end

    def allocate_selected_tickets!(refund)
      refund.refund_tickets.includes(ticket: :order_item).group_by { |entry| entry.ticket.order_item }.each do |item, entries|
        allocation = entries.sum(&:amount_cents)
        successful_allocations = RefundItem.joins(:refund)
          .where(order_item: item, refunds: { status: Refund.statuses[:succeeded] })
        weights = [
          item.organizer_proceeds_cents - successful_allocations.sum(:organizer_proceeds_cents),
          item.fee_cents - successful_allocations.sum(:fee_cents),
          item.organizer_fee_cents - successful_allocations.sum(:organizer_fee_cents),
          item.tax_cents - successful_allocations.sum(:tax_cents)
        ].map { |value| [value, 0].max }
        raise RefundError, "Selected ticket refund could not be allocated" if weights.sum < allocation

        components = MoneyAllocator.call(allocation, weights)
        refund.refund_items.create!(
          order_item: item,
          amount_cents: allocation,
          organizer_proceeds_cents: components[0],
          fee_cents: components[1],
          organizer_fee_cents: components[2],
          tax_cents: components[3],
          quantity: entries.length
        )
      end
    end

    def update_payment_refund_status!(payment, succeeded_total)
      return unless payment

      payment.update!(status: succeeded_total >= payment.amount_cents ? :refunded : :partially_refunded)
    end

    def resolve_repaid_late_capture!(refund)
      return unless refund.payment.refunded? && refund.order.completed_at.nil? && refund.order.tickets.empty?

      ReconciliationException.open.where(order: refund.order, payment: refund.payment,
        code: %w[late_payment_success_after_inventory_release late_payment_success_after_hold_expiry]).find_each(&:resolve!)
    end

    def release_fully_refunded_inventory!(refund)
      refunded_order = refund.order
      if refunded_order.completed_at.nil? && refunded_order.tickets.empty? &&
          ReconciliationException.where(order: refunded_order, payment: refund.payment,
            code: %w[late_payment_success_after_inventory_release late_payment_success_after_hold_expiry]).exists?
        return
      end
      refunded_order.tickets.includes(:ticket_type, :pricing_tier).where.not(status: :cancelled).order(:id).lock.each do |ticket|
        FinancialReversalInventory.call(ticket: ticket, refund: refund, reason: reason)
      end
      refunded_order.order_items.where.not(item_kind: OrderItem.item_kinds[:ticket]).find_each do |item|
        next if item.catalog_fulfillment&.fulfilled?

        item.catalog_item.lock!
        item.catalog_item.decrement!(:quantity_sold, item.quantity)
        item.catalog_fulfillment&.cancel! unless item.catalog_fulfillment&.cancelled?
      end
    end

    def release_refunded_tickets!(refund)
      refund.tickets.includes(:ticket_type, :pricing_tier).order(:id).lock.each do |ticket|
        FinancialReversalInventory.call(ticket: ticket, refund: refund, reason: reason)
      end
    end

    def record_promoter_commission_reversal!(refund)
      attribution = refund.order.referral_attribution
      return unless attribution

      entries = refund.order.promoter_commission_entries
      earned = entries.earned.sum(:amount_cents)
      already_reversed = entries.refund_reversal.sum(:amount_cents).abs
      cumulative_refunded_proceeds = RefundItem.joins(:refund)
        .where(refunds: { order_id: refund.order_id, status: Refund.statuses[:succeeded] })
        .sum(:organizer_proceeds_cents)
      desired_reversal = [attribution.promoter.commission_for(cumulative_refunded_proceeds), earned].min
      amount = desired_reversal - already_reversed
      return unless amount.positive?

      refund.promoter_commission_entries.create!(
        promoter: attribution.promoter,
        order: refund.order,
        kind: :refund_reversal,
        amount_cents: -amount,
        currency: refund.currency,
        idempotency_key: "commission:refund:#{refund.id}",
        occurred_at: Time.current
      )
    end
  end
end
