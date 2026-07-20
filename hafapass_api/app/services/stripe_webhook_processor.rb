# frozen_string_literal: true

require "ostruct"

class StripeWebhookProcessor
  class ProcessingError < StandardError; end

  def self.call(event:, payload:)
    new(event: event, payload: payload).call
  end

  def initialize(event:, payload:)
    @event = event
    @payload = payload
  end

  def call
    receipt = store_receipt!
    return receipt if receipt.processed? || receipt.ignored?

    receipt.update!(status: :processing, attempts: receipt.attempts + 1, last_error: nil)
    process!(receipt)
    receipt
  rescue StandardError => e
    receipt&.update!(status: :failed, last_error: "#{e.class}: #{e.message}")
    raise
  end

  private

  attr_reader :event, :payload

  def store_receipt!
    WebhookEvent.create!(
      provider: "stripe",
      provider_event_id: event.id,
      event_type: event.type,
      payload: payload,
      provider_created_at: event.respond_to?(:created) && event.created ? Time.zone.at(event.created.to_i) : nil
    )
  rescue ActiveRecord::RecordNotUnique, ActiveRecord::RecordInvalid
    WebhookEvent.find_by!(provider: "stripe", provider_event_id: event.id)
  end

  def process!(receipt)
    object = event.data.object
    payment = find_payment(object)
    create_payment_event!(receipt, payment, object)

    case event.type
    when "payment_intent.succeeded"
      process_success!(receipt, payment, object)
    when "payment_intent.payment_failed"
      process_failure!(payment, object)
    when "payment_intent.canceled"
      process_cancellation!(payment)
    when "charge.refunded"
      process_refund!(receipt, payment, object)
    else
      receipt.update!(status: :ignored, processed_at: Time.current)
      return
    end

    receipt.update!(status: :processed, processed_at: Time.current)
  end

  def find_payment(object)
    provider_payment_id = if event.type.start_with?("payment_intent.")
      value(object, :id)
    else
      value(object, :payment_intent)
    end
    return if provider_payment_id.blank?

    Payment.find_by(provider: "stripe", provider_payment_id: provider_payment_id) ||
      backfill_legacy_payment(provider_payment_id)
  end

  def backfill_legacy_payment(provider_payment_id)
    order = Order.find_by(stripe_payment_intent_id: provider_payment_id)
    return unless order

    order.payments.create!(
      provider: "stripe",
      provider_payment_id: provider_payment_id,
      idempotency_key: "legacy:order:#{order.id}",
      amount_cents: order.total_cents,
      currency: order.currency,
      status: order.completed? ? :succeeded : :pending,
      succeeded_at: order.completed_at
    )
  rescue ActiveRecord::RecordNotUnique
    Payment.find_by(provider: "stripe", provider_payment_id: provider_payment_id)
  end

  def create_payment_event!(receipt, payment, object)
    return if receipt.payment_event

    receipt.create_payment_event!(
      payment: payment,
      event_type: event.type,
      amount_cents: value(object, :amount_received) || value(object, :amount_refunded) || value(object, :amount),
      currency: value(object, :currency)&.downcase,
      provider_created_at: receipt.provider_created_at,
      data: normalized_event_data(object)
    )
  end

  def process_success!(receipt, payment, object)
    unless payment
      ReconciliationException.create!(webhook_event: receipt, code: "payment_not_found")
      return
    end

    Commerce::OrderLifecycle.complete!(
      payment.order,
      payment: payment,
      webhook_event: receipt,
      provider_amount_cents: value(object, :amount_received) || value(object, :amount),
      provider_currency: value(object, :currency),
      wallet_type: value(object, :wallet_type)
    )
  end

  def process_failure!(payment, object)
    return unless payment

    error = value(object, :last_payment_error)
    Commerce::OrderLifecycle.fail!(
      payment.order,
      payment: payment,
      failure_code: nested_value(error, :code),
      failure_message: nested_value(error, :message),
      reason: "payment_failed"
    )
  end

  def process_cancellation!(payment)
    return unless payment

    Commerce::OrderLifecycle.fail!(payment.order, payment: payment, reason: "payment_cancelled")
  end

  def process_refund!(receipt, payment, object)
    unless payment
      ReconciliationException.create!(webhook_event: receipt, code: "refunded_payment_not_found")
      return
    end

    provider_total = value(object, :amount_refunded).to_i
    if payment.order.order_items.empty?
      ReconciliationException.create!(
        order: payment.order,
        payment: payment,
        webhook_event: receipt,
        code: "refund_missing_order_item_ledger",
        actual_amount_cents: provider_total
      )
      return
    end
    succeeded_total = payment.order.refunds.succeeded.sum(:amount_cents)
    if provider_total < succeeded_total
      ReconciliationException.create!(
        order: payment.order,
        payment: payment,
        webhook_event: receipt,
        code: "provider_refund_total_decreased",
        expected_amount_cents: succeeded_total,
        actual_amount_cents: provider_total
      )
      return
    end
    return if provider_total == succeeded_total

    Commerce::RefundCreator.reconcile_provider_total!(
      order: payment.order,
      payment: payment,
      amount_cents: provider_total,
      provider_refund_id: provider_refund_id(object) || "webhook_re_#{receipt.provider_event_id}",
      idempotency_key: "webhook:#{receipt.provider_event_id}:refund",
    )
  end

  def provider_refund_id(object)
    refunds = value(object, :refunds)
    data = nested_value(refunds, :data)
    Array(data).filter_map { |provider_refund| value(provider_refund, :id) }
      .find { |id| !Refund.exists?(provider: "stripe", provider_refund_id: id) }
  end

  def normalized_event_data(object)
    {
      provider_object_id: value(object, :id),
      payment_intent_id: value(object, :payment_intent),
      status: value(object, :status)
    }.compact
  end

  def value(object, key)
    return object.public_send(key) if object.respond_to?(key)
    return object[key] if object.respond_to?(:key?) && object.key?(key)
    object[key.to_s] if object.respond_to?(:key?) && object.key?(key.to_s)
  end

  def nested_value(object, key)
    object ? value(object, key) : nil
  end
end
