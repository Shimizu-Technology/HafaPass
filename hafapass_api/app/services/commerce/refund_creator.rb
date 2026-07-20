# frozen_string_literal: true

require "ostruct"

module Commerce
  class RefundCreator
    class RefundError < StandardError; end

    def self.call(**)
      new(**).call
    end

    def self.reconcile_provider_total!(order:, payment:, amount_cents:, provider_refund_id:, idempotency_key:)
      succeeded_total = order.refunds.succeeded.sum(:amount_cents)
      delta = amount_cents.to_i - succeeded_total
      return if delta <= 0

      provider_refund = OpenStruct.new(id: provider_refund_id, status: "succeeded")
      pending = order.refunds.pending.where(payment: payment, amount_cents: delta).order(:id).first
      creator = new(
        order: order,
        amount_cents: delta,
        reason: "provider_webhook_reconciliation",
        idempotency_key: idempotency_key,
        provider_refund: provider_refund
      )
      return creator.send(:finalize_refund!, pending, provider_refund) if pending

      creator.call
    end

    def initialize(order:, amount_cents: nil, reason: nil, requested_by: nil, idempotency_key: nil,
      provider_refund: nil)
      @order = order
      @requested_amount_cents = amount_cents&.to_i
      @reason = reason
      @requested_by = requested_by
      @idempotency_key = idempotency_key.presence || "refund:order:#{order.id}:#{SecureRandom.uuid}"
      @provider_refund = provider_refund
    end

    def call
      refund = reserve_refund!
      return refund unless refund.pending?

      provider_refund = submit_provider_refund(refund)
      finalize_refund!(refund, provider_refund)
    rescue Stripe::StripeError, StripeService::PaymentError => e
      refund&.update!(status: :failed, failed_at: Time.current, failure_code: "provider_error", failure_message: e.message)
      raise RefundError, "Refund provider rejected the request"
    end

    private

    attr_reader :order, :requested_amount_cents, :reason, :requested_by, :idempotency_key, :provider_refund

    def reserve_refund!
      existing = order.refunds.find_by(idempotency_key: idempotency_key)
      return existing if existing

      Order.transaction do
        order.lock!
        unless order.completed? || order.partially_refunded?
          raise RefundError, "Only completed or partially refunded orders can be refunded"
        end

        payment = order.payments.succeeded.order(:id).last
        remaining = order.refundable_cents
        amount = requested_amount_cents || remaining
        raise RefundError, "Refund amount must be positive" unless amount.positive?
        raise RefundError, "Refund amount exceeds refundable balance" if amount > remaining

        order.refunds.create!(
          payment: payment,
          requested_by: requested_by,
          provider: payment&.provider || "stripe",
          idempotency_key: idempotency_key,
          amount_cents: amount,
          currency: order.currency,
          status: :pending,
          reason: reason
        )
      end
    rescue ActiveRecord::RecordNotUnique, ActiveRecord::RecordInvalid => e
      existing = order.refunds.find_by(idempotency_key: idempotency_key)
      raise e unless existing

      existing
    end

    def submit_provider_refund(refund)
      return provider_refund if provider_refund

      payment = refund.payment
      if payment&.provider_payment_id.present? && !payment.provider_payment_id.start_with?("sim_")
        StripeService.refund_payment(
          payment.provider_payment_id,
          amount_cents: refund.amount_cents,
          reason: reason,
          idempotency_key: refund.idempotency_key
        )
      else
        OpenStruct.new(id: "sim_re_#{SecureRandom.hex(12)}", status: "succeeded")
      end
    end

    def finalize_refund!(refund, provider_refund)
      full_refund = false

      Refund.transaction do
        refund.lock!
        return refund if refund.succeeded?

        refund.order.lock!
        refund.update!(
          provider_refund_id: provider_refund.id,
          provider_payload: { status: provider_refund.respond_to?(:status) ? provider_refund.status : nil }.compact,
          status: :succeeded,
          succeeded_at: Time.current
        )
        allocate_items!(refund)

        succeeded_total = refund.order.refunds.succeeded.sum(:amount_cents)
        full_refund = succeeded_total >= refund.order.total_cents
        refund.order.update!(
          status: full_refund ? :refunded : :partially_refunded,
          refund_amount_cents: succeeded_total,
          refund_reason: reason,
          refunded_at: Time.current,
          stripe_refund_id: provider_refund.id
        )
        update_payment_refund_status!(refund.payment, succeeded_total)
        release_fully_refunded_inventory!(refund.order) if full_refund
      end

      EmailService.send_refund_notification_async(refund.order)
      refund.order.event.notify_waitlist_if_available if full_refund
      refund.reload
    end

    def allocate_items!(refund)
      remaining = refund.amount_cents
      refund.order.order_items.order(:id).each do |item|
        successful_allocations = RefundItem.joins(:refund)
          .where(order_item: item, refunds: { status: Refund.statuses[:succeeded] })
        organizer_remaining = item.organizer_proceeds_cents - successful_allocations.sum(:organizer_proceeds_cents)
        fee_remaining = item.fee_cents - successful_allocations.sum(:fee_cents)
        tax_remaining = item.tax_cents - successful_allocations.sum(:tax_cents)
        available = organizer_remaining + fee_remaining + tax_remaining
        allocation = [remaining, available].min
        next if allocation.zero?

        components = MoneyAllocator.call(allocation, [organizer_remaining, fee_remaining, tax_remaining])
        refund.refund_items.create!(
          order_item: item,
          amount_cents: allocation,
          organizer_proceeds_cents: components[0],
          fee_cents: components[1],
          tax_cents: components[2],
          quantity: 0
        )
        remaining -= allocation
        break if remaining.zero?
      end

      raise RefundError, "Refund could not be allocated to order items" unless remaining.zero?
    end

    def update_payment_refund_status!(payment, succeeded_total)
      return unless payment

      payment.update!(status: succeeded_total >= payment.amount_cents ? :refunded : :partially_refunded)
    end

    def release_fully_refunded_inventory!(refunded_order)
      refunded_order.tickets.includes(:ticket_type, :pricing_tier).where.not(status: :cancelled).each do |ticket|
        ticket.release_inventory!
        ticket.update!(status: :cancelled)
      end
    end
  end
end
