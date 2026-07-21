# frozen_string_literal: true

class MessageDeliveryJob < ApplicationJob
  queue_as :emails

  retry_on StandardError, wait: :polynomially_longer, attempts: 5

  def perform(delivery_id)
    delivery = MessageDelivery.find(delivery_id)
    delivery.with_lock do
      if terminal?(delivery)
        mark_reminder_sent!(delivery) if delivery.sent? || delivery.delivered?
        return
      end

      if obsolete_reminder?(delivery)
        delivery.update!(status: :suppressed, suppressed_at: Time.current,
          last_error: "Reminder was cancelled or rescheduled")
        return
      end

      if delivery.suppressed_recipient?
        delivery.update!(status: :suppressed, suppressed_at: Time.current,
          last_error: "Recipient has a prior bounce, complaint, or suppression")
        return
      end

      delivery.update!(attempts: delivery.attempts + 1, status: :queued, last_error: nil)
      response = dispatch(delivery)
      delivery.update!(
        status: :sent,
        provider_id: provider_id(response),
        sent_at: Time.current,
        failed_at: nil,
        last_error: nil
      )
      mark_reminder_sent!(delivery)
    end
    MessageProviderEventProcessor.reconcile_for!(delivery)
  rescue StandardError => e
    delivery&.with_lock do
      unless terminal?(delivery)
        delivery.update_columns(
          status: MessageDelivery.statuses.fetch("failed"),
          attempts: delivery.attempts + 1,
          failed_at: Time.current,
          last_error: "#{e.class}: #{e.message}".first(1000),
          updated_at: Time.current
        )
      end
    end
    Sentry.capture_exception(e, extra: { message_delivery_id: delivery_id })
    raise
  end

  private

  def terminal?(delivery)
    delivery.sent? || delivery.delivered? || delivery.bounced? || delivery.complained? || delivery.suppressed?
  end

  def obsolete_reminder?(delivery)
    return false unless delivery.template == "event_reminder"

    reminder = EventReminder.find_by(id: delivery.metadata["event_reminder_id"])
    scheduled_for = delivery.metadata["scheduled_for"]
    reminder.nil? || !reminder.pending? || scheduled_for.blank? || reminder.remind_at.iso8601(6) != scheduled_for
  end

  def mark_reminder_sent!(delivery)
    return unless delivery.template == "event_reminder"

    reminder = EventReminder.find_by(id: delivery.metadata["event_reminder_id"])
    return unless reminder&.pending?
    return unless reminder.remind_at.iso8601(6) == delivery.metadata["scheduled_for"]

    reminder.update!(status: :sent, sent_at: delivery.sent_at || Time.current)
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
    when "ticket_transfer"
      transfer = TicketTransfer.find(delivery.metadata.fetch("ticket_transfer_id"))
      EmailService.send_ticket_transfer(transfer, delivery: delivery)
    when "waitlist_offer"
      offer = WaitlistOffer.find(delivery.metadata.fetch("waitlist_offer_id"))
      EmailService.send_waitlist_offer(offer, delivery: delivery)
    when "communication_campaign"
      EmailService.send_communication_campaign(delivery)
    when "event_reminder"
      reminder = EventReminder.find(delivery.metadata.fetch("event_reminder_id"))
      EmailService.send_event_reminder(reminder, delivery: delivery)
    else
      raise ArgumentError, "Unsupported message template"
    end
  end

  def provider_id(response)
    return if response.blank? || response[:simulated]

    response[:id] || response["id"]
  end
end
