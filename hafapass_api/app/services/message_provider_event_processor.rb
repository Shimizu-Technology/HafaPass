# frozen_string_literal: true

class MessageProviderEventProcessor
  STATUS_BY_EVENT = {
    "email.sent" => :sent,
    "email.delivered" => :delivered,
    "email.delivery_delayed" => :delayed,
    "email.failed" => :failed,
    "email.bounced" => :bounced,
    "email.complained" => :complained,
    "email.suppressed" => :suppressed
  }.freeze

  def self.call(provider_event_id:, event:)
    new(provider_event_id: provider_event_id, event: event).call
  end

  def self.reconcile_for!(delivery)
    return if delivery.provider_id.blank?

    MessageProviderEvent.where(provider: delivery.provider, provider_message_id: delivery.provider_id,
      processed_at: nil).find_each do |receipt|
      new(provider_event_id: receipt.provider_event_id, event: nil).process_receipt!(receipt, delivery)
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
    delivery = MessageDelivery.find_by(provider: "resend", provider_id: provider_message_id)
    receipt = MessageProviderEvent.find_or_create_by!(provider: "resend", provider_event_id: provider_event_id) do |record|
      record.assign_attributes(
        message_delivery: delivery, provider_message_id: provider_message_id, event_type: event_type,
        occurred_at: occurred_at, received_at: Time.current, payload: safe_payload
      )
    end
    return receipt if receipt.processed_at.present?
    return receipt unless delivery

    process_receipt!(receipt, delivery)
  rescue StandardError => e
    receipt&.update_columns(processing_error: "#{e.class}: #{e.message}".first(1000), updated_at: Time.current)
    Sentry.capture_exception(e, extra: { provider: "resend", provider_event_id: provider_event_id })
    raise
  end

  def process_receipt!(receipt, delivery)
    MessageProviderEvent.transaction do
      receipt.lock!
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
    data.fetch("email_id")
  end

  def occurred_at
    Time.iso8601(event.fetch("created_at"))
  end

  def safe_payload
    {
      "bounce" => data["bounce"].is_a?(Hash) ? data["bounce"].slice("type", "subType", "message") : nil,
      "tags" => data["tags"].is_a?(Hash) ? data["tags"].slice("category") : nil
    }.compact
  end

  def apply_to_delivery!(delivery, receipt)
    status = STATUS_BY_EVENT[receipt.event_type]
    return unless status

    delivery.with_lock do
      return if delivery.last_event_at.present? && receipt.occurred_at < delivery.last_event_at

      attributes = { status: status, last_event_at: receipt.occurred_at, last_error: failure_message(receipt) }
      attributes[timestamp_column(status)] = receipt.occurred_at if timestamp_column(status)
      delivery.update!(attributes)
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

    receipt.payload.dig("bounce", "message") || "Provider reported #{receipt.event_type.delete_prefix('email.')}"
  end
end
