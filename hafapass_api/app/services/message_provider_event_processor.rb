# frozen_string_literal: true

class MessageProviderEventProcessor
  class InvalidMessageId < ResendWebhookVerifier::VerificationError; end

  STATUS_BY_EVENT = {
    "email.sent" => :sent,
    "email.delivered" => :delivered,
    "email.delivery_delayed" => :delayed,
    "email.failed" => :failed,
    "email.bounced" => :bounced,
    "email.complained" => :complained,
    "email.suppressed" => :suppressed
  }.freeze

  # docs/LOCKING.md: only these forward transitions may change a delivery.
  # Hard bounce, invalid address, complaint, and suppression are terminal even
  # when a contradictory receipt carries a newer provider timestamp.
  ALLOWED_TRANSITIONS = {
    "queued" => %i[sent delivered delayed failed bounced complained suppressed],
    "sent" => %i[delivered delayed failed bounced complained suppressed],
    "delayed" => %i[delivered failed bounced complained suppressed],
    "failed" => %i[delivered delayed failed bounced complained suppressed],
    "delivered" => %i[failed bounced complained suppressed], # failed only for an invalid address
    "bounced" => %i[delivered bounced complained suppressed], # only a transient bounce can recover
    "complained" => [], "suppressed" => [], "cancelled" => []
  }.freeze

  def self.call(provider_event_id:, event:)
    new(provider_event_id: provider_event_id, event: event).call
  end

  def self.reconcile_for!(delivery)
    return unless delivery.provider_id.is_a?(String) && delivery.provider_id.present?

    MessageProviderEvent.where(provider: delivery.provider, provider_message_id: delivery.provider_id,
      processed_at: nil).find_each do |receipt|
      new(provider_event_id: receipt.provider_event_id, event: nil).process_receipt!(receipt, delivery)
    rescue InvalidMessageId
      next
    rescue StandardError => e
      receipt.update_columns(processing_error: "#{e.class}: #{e.message}".first(1000), updated_at: Time.current)
      Sentry.capture_exception(e, extra: { provider: delivery.provider, provider_event_id: receipt.provider_event_id })
    end
  end

  def initialize(provider_event_id:, event:)
    @provider_event_id = provider_event_id
    @event = event
  end

  def call
    message_id = provider_message_id
    delivery = MessageDelivery.find_by(provider: "resend", provider_id: message_id)
    receipt = MessageProviderEvent.find_or_create_by!(provider: "resend", provider_event_id: provider_event_id) do |record|
      record.assign_attributes(
        message_delivery: delivery, provider_message_id: message_id, event_type: event_type,
        occurred_at: occurred_at, received_at: Time.current, payload: safe_payload
      )
    end
    validate_receipt_identity!(receipt, provider: "resend", message_id: message_id)
    return receipt if receipt.processed_at.present?
    return receipt unless delivery

    process_receipt!(receipt, delivery)
  rescue InvalidMessageId
    raise
  rescue StandardError => e
    receipt&.update_columns(processing_error: "#{e.class}: #{e.message}".first(1000), updated_at: Time.current)
    Sentry.capture_exception(e, extra: { provider: "resend", provider_event_id: provider_event_id })
    raise
  end

  def process_receipt!(receipt, delivery)
    MessageProviderEvent.transaction do
      receipt.lock!
      validate_receipt_identity!(receipt, provider: delivery.provider, message_id: delivery.provider_id)
      return receipt if receipt.processed_at.present?

      apply_to_delivery!(delivery, receipt)
      receipt.update!(message_delivery: delivery, processed_at: Time.current, processing_error: nil)
      receipt
    end
  end

  private

  attr_reader :provider_event_id, :event

  def event_type
    event.fetch("type")
  end

  def data
    value = event.fetch("data")
    raise ArgumentError, "Webhook data must be an object" unless value.is_a?(Hash)

    value
  end

  def provider_message_id
    validate_message_id!(data["email_id"])
  end

  def validate_message_id!(value)
    unless value.is_a?(String) && value.present?
      raise InvalidMessageId, "Webhook email_id must be a nonblank string"
    end

    value
  end

  def validate_receipt_identity!(receipt, provider:, message_id:)
    validate_message_id!(receipt.provider_message_id)
    return if receipt.provider == provider && receipt.provider_message_id == message_id

    raise InvalidMessageId, "Webhook email_id does not match the stored receipt identity"
  end

  def occurred_at
    Time.iso8601(event.fetch("created_at"))
  end

  def safe_payload
    {
      "bounce" => data["bounce"].is_a?(Hash) ? data["bounce"].slice("type", "subType", "message", "code", "diagnosticCode") : nil,
      "failed" => data["failed"].is_a?(Hash) ? data["failed"].slice("reason") : nil,
      "error" => data["error"].is_a?(Hash) ? data["error"].slice("code", "message") : nil,
      "tags" => data["tags"].is_a?(Hash) ? data["tags"].slice("category") : nil
    }.compact
  end

  def apply_to_delivery!(delivery, receipt)
    status = STATUS_BY_EVENT[receipt.event_type]
    return unless status

    WaitlistLocks.for_delivery(delivery) do
      invalid_address = %i[failed bounced].include?(status) && MessageAddressFailure.receipt?(receipt)
      status = :suppressed if status == :failed && invalid_address
      terminal_failure = delivery.complained? || delivery.suppressed? ||
        (delivery.bounced? && !WaitlistDelivery.transient_bounce?(delivery)) ||
        delivery.metadata["provider_address_invalid"] == true
      return if terminal_failure || !ALLOWED_TRANSITIONS.fetch(delivery.status).include?(status)
      return if delivery.delivered? && status == :failed && !invalid_address
      # A definitive failure wins even when its webhook arrives after a newer
      # success receipt. Nonterminal provider updates still follow event time.
      definitive = %i[complained suppressed].include?(status) ||
        (status == :bounced && receipt.payload.dig("bounce", "type") != "Transient")
      return if !definitive && delivery.last_event_at.present? && receipt.occurred_at < delivery.last_event_at

      attributes = { status: status, last_event_at: receipt.occurred_at, last_error: failure_message(receipt),
        reconciled_at: nil }
      attributes[:metadata] = delivery.metadata.merge("provider_address_invalid" => true) if invalid_address
      attributes[timestamp_column(status)] = receipt.occurred_at if timestamp_column(status)
      delivery.update!(attributes)
      WaitlistDelivery.reconcile_success_locked!(delivery) if status == :delivered
      WaitlistDelivery.reconcile_failure!(delivery) if %i[failed bounced complained suppressed].include?(status)
    end
  end

  def timestamp_column(status)
    {
      delivered: :delivered_at,
      failed: :failed_at,
      bounced: :bounced_at,
      complained: :complained_at,
      suppressed: :suppressed_at
    }[status]
  end

  def failure_message(receipt)
    return unless %i[failed bounced complained suppressed].include?(STATUS_BY_EVENT[receipt.event_type])

    receipt.payload.dig("error", "message") || receipt.payload.dig("bounce", "message") ||
      receipt.payload.dig("failed", "reason") ||
      "Provider reported #{receipt.event_type.delete_prefix('email.')}"
  end
end
