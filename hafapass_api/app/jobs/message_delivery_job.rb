# frozen_string_literal: true

class MessageDeliveryJob < ApplicationJob
  queue_as :emails

  retry_on StandardError, wait: :polynomially_longer, attempts: 5

  def perform(delivery_id)
    delivery = MessageDelivery.find(delivery_id)
    return if terminal?(delivery)

    if delivery.suppressed_recipient?
      delivery.update!(status: :suppressed, suppressed_at: Time.current,
        last_error: "Recipient has a prior bounce, complaint, or suppression")
      return
    end

    delivery.with_lock do
      return if terminal?(delivery)

      delivery.update!(attempts: delivery.attempts + 1, status: :queued, last_error: nil)
    end

    response = dispatch(delivery)
    delivery.update!(
      status: :sent,
      provider_id: provider_id(response),
      sent_at: Time.current,
      failed_at: nil,
      last_error: nil
    )
    MessageProviderEventProcessor.reconcile_for!(delivery)
  rescue StandardError => e
    delivery&.update_columns(
      status: MessageDelivery.statuses.fetch("failed"),
      failed_at: Time.current,
      last_error: "#{e.class}: #{e.message}".first(1000),
      updated_at: Time.current
    )
    Sentry.capture_exception(e, extra: { message_delivery_id: delivery_id })
    raise
  end

  private

  def terminal?(delivery)
    delivery.sent? || delivery.delivered? || delivery.bounced? || delivery.complained? || delivery.suppressed?
  end

  def dispatch(delivery)
    case delivery.template
    when "order_confirmation", "fulfillment_resend"
      EmailService.send_order_confirmation(delivery.order, delivery: delivery)
    when "ticket_delivery"
      EmailService.send_ticket_email(delivery.ticket, delivery: delivery)
    when "order_recovery"
      EmailService.send_order_recovery(delivery.order, delivery: delivery)
    when "event_change"
      change = EventChange.find(delivery.metadata.fetch("event_change_id"))
      EmailService.send_event_change_notification(change, delivery.order, delivery: delivery)
    when "refund_notification"
      EmailService.send_refund_notification(delivery.order, delivery: delivery)
    when "guest_list"
      entry = GuestListEntry.find(delivery.metadata.fetch("guest_list_entry_id"))
      EmailService.send_guest_list_notification(entry, delivery: delivery)
    when "waitlist_notification"
      entry = WaitlistEntry.find(delivery.metadata.fetch("waitlist_entry_id"))
      EmailService.send_waitlist_notification(entry, delivery: delivery)
    else
      raise ArgumentError, "Unsupported message template"
    end
  end

  def provider_id(response)
    return if response.blank? || response[:simulated]

    response[:id] || response["id"]
  end
end
