# frozen_string_literal: true

require "digest"

class EmailService
  FROM_EMAIL = ENV.fetch("MAILER_FROM_EMAIL", "tickets@hafapass.com")

  class << self
    def configured?
      ENV["RESEND_API_KEY"].present?
    end

    # ── Async Methods (use these from controllers) ──────────────────
    # These enqueue background jobs for better performance

    def send_order_confirmation_async(order, requested_by: nil, template: "order_confirmation")
      delivery = create_delivery(order: order, event: order.event, requested_by: requested_by, template: template,
        recipient: order.buyer_email)
      MessageDeliveryJob.perform_later(delivery.id)
      delivery
    rescue StandardError => e
      record_enqueue_failure(delivery, e)
      raise
    end

    def send_ticket_email_async(ticket, requested_by: nil)
      delivery = create_delivery(ticket: ticket, order: ticket.order, event: ticket.event, requested_by: requested_by,
        template: "ticket_delivery", recipient: ticket.attendee_email)
      MessageDeliveryJob.perform_later(delivery.id)
      delivery
    rescue StandardError => e
      record_enqueue_failure(delivery, e)
      raise
    end

    def send_order_recovery_async(order)
      delivery = create_delivery(order: order, event: order.event, template: "order_recovery", recipient: order.buyer_email)
      MessageDeliveryJob.perform_later(delivery.id)
      delivery
    rescue StandardError => e
      record_enqueue_failure(delivery, e)
      raise
    end

    def send_event_change_notifications_async(change)
      change.event.orders.where(status: [:completed, :partially_refunded]).find_each do |order|
        delivery = nil
        delivery = create_delivery(order: order, event: change.event, template: "event_change",
          recipient: order.buyer_email, metadata: { event_change_id: change.id })
        MessageDeliveryJob.perform_later(delivery.id)
      rescue StandardError => e
        record_enqueue_failure(delivery, e)
        Rails.logger.error(
          "[EventChangeNotification] Unable to queue change=#{change.id} order=#{order.id}: #{e.class}"
        )
      end
    end

    def send_refund_notification_async(order)
      delivery = create_delivery(order: order, event: order.event, template: "refund_notification",
        recipient: order.buyer_email)
      MessageDeliveryJob.perform_later(delivery.id)
      delivery
    end

    def send_guest_list_notification_async(guest_entry)
      return unless guest_entry.guest_email.present?

      delivery = create_delivery(event: guest_entry.event, template: "guest_list", recipient: guest_entry.guest_email,
        metadata: { guest_list_entry_id: guest_entry.id })
      MessageDeliveryJob.perform_later(delivery.id)
      delivery
    end

    def send_waitlist_notification_async(waitlist_entry)
      return unless waitlist_entry.email.present?

      delivery = create_delivery(event: waitlist_entry.event, template: "waitlist_notification",
        recipient: waitlist_entry.email, metadata: { waitlist_entry_id: waitlist_entry.id })
      MessageDeliveryJob.perform_later(delivery.id)
      delivery
    end

    def send_ticket_transfer_async(transfer)
      delivery = create_delivery(ticket: transfer.ticket, order: transfer.ticket.order, event: transfer.ticket.event,
        template: "ticket_transfer", recipient: transfer.recipient_email,
        metadata: { ticket_transfer_id: transfer.id })
      MessageDeliveryJob.perform_later(delivery.id)
      delivery
    end

    def send_waitlist_offer_async(offer)
      delivery = create_delivery(event: offer.event, template: "waitlist_offer",
        recipient: offer.waitlist_entry.email, metadata: { waitlist_offer_id: offer.id })
      MessageDeliveryJob.perform_later(delivery.id)
      delivery
    end

    def send_event_reminder_async(reminder)
      delivery = create_delivery(event: reminder.event, requested_by: reminder.user, template: "event_reminder",
        recipient: reminder.user.email,
        metadata: { event_reminder_id: reminder.id, scheduled_for: reminder.remind_at.iso8601(6) },
        idempotency_key: "event-reminder/#{reminder.id}/#{reminder.remind_at.utc.strftime('%Y%m%d%H%M%S%6N')}")
      MessageDeliveryJob.perform_later(delivery.id)
      delivery
    rescue StandardError => e
      record_enqueue_failure(delivery, e)
      raise
    end

    # ── Order Confirmation ──────────────────────────────────────────
    def send_order_confirmation(order, delivery: nil)
      event = order.event
      tickets = order.tickets.includes(:ticket_type)
      html = build_order_confirmation_html(order, event, tickets)
      subject = safe_subject("Your HafaPass Tickets - #{event.title}")

      deliver(to: order.buyer_email, subject: subject, html: html, tag: "order_confirmation", delivery: delivery,
        order_id: order.id)
    end

    def send_order_recovery(order, delivery: nil)
      html = build_order_recovery_html(order)
      deliver(
        to: order.buyer_email,
        subject: "Access your HafaPass order #{order.reference}",
        html: html,
        tag: "order_recovery",
        delivery: delivery, order_id: order.id
      )
    end

    def send_event_change_notification(change, order, delivery: nil)
      action = change.change_type.humanize.downcase
      html = email_wrapper("Event #{action}") do
        <<~HTML
          <h2 style="color: #1f2937; margin: 0 0 8px; font-size: 22px;">#{ERB::Util.html_escape(change.event.title)} was #{action}</h2>
          <p style="color: #6b7280; margin: 0 0 20px;">#{ERB::Util.html_escape(change.reason || 'The organizer updated this event.')}</p>
          <p style="color: #6b7280; margin: 0 0 24px;">Review the latest details and choose whether to keep your tickets or request an eligible refund.</p>
          <a href="#{order_access_url(order)}" style="display: inline-block; background: #0e7c7b; color: white; text-decoration: none; padding: 14px 28px; border-radius: 10px; font-weight: 600;">Review order #{order.reference}</a>
        HTML
      end
      deliver(to: order.buyer_email, subject: safe_subject("Important update: #{change.event.title}"), html: html,
        tag: "event_change", delivery: delivery, order_id: order.id)
    end

    # ── Individual Ticket Email ─────────────────────────────────────
    def send_ticket_email(ticket, delivery: nil)
      event = ticket.event
      ticket_type = ticket.ticket_type
      html = build_ticket_email_html(ticket, event, ticket_type)
      subject = safe_subject("Your Ticket - #{event.title}")

      deliver(to: ticket.attendee_email, subject: subject, html: html, tag: "ticket_delivery", delivery: delivery,
        ticket_id: ticket.id)
    end

    # ── Refund Notification ─────────────────────────────────────────
    def send_refund_notification(order, delivery: nil)
      event = order.event
      html = build_refund_notification_html(order, event)
      subject = safe_subject("Refund Processed - #{event.title}")

      deliver(to: order.buyer_email, subject: subject, html: html, tag: "refund_notification", delivery: delivery,
        order_id: order.id)
    end

    # ── Waitlist Notification ──────────────────────────────────────
    def send_waitlist_notification(waitlist_entry, delivery: nil)
      return unless waitlist_entry.email.present?

      event = waitlist_entry.event
      frontend_url = ENV.fetch("FRONTEND_URL", "http://localhost:5173")
      event_url = "#{frontend_url}/events/#{event.slug}"
      html = build_waitlist_notification_html(waitlist_entry, event, event_url)
      subject = safe_subject("Tickets Available - #{event.title}")

      deliver(to: waitlist_entry.email, subject: subject, html: html, tag: "waitlist_notification", delivery: delivery,
        entry_id: waitlist_entry.id)
    end

    def send_ticket_transfer(transfer, delivery: nil)
      url = "#{frontend_url}/ticket-transfers/accept?token=#{ERB::Util.url_encode(TicketTransferCredential.issue(transfer))}"
      html = email_wrapper("Ticket transfer") do
        <<~HTML
          <h2 style="color:#1f2937">A HafaPass ticket was sent to you</h2>
          <p style="color:#6b7280">#{h(transfer.ticket.event.title)} — #{h(transfer.ticket.ticket_type.name)}</p>
          <p><a href="#{url}" style="display:inline-block;background:#0e7c7b;color:white;padding:14px 28px;border-radius:10px;text-decoration:none">Accept ticket</a></p>
          <p style="color:#6b7280;font-size:14px">Sign in using #{h(transfer.recipient_email)}. This link expires #{h(transfer.expires_at.iso8601)}.</p>
        HTML
      end
      deliver(to: transfer.recipient_email, subject: safe_subject("Ticket transfer: #{transfer.ticket.event.title}"),
        html: html, tag: "ticket_transfer", delivery: delivery, ticket_id: transfer.ticket_id)
    end

    def send_waitlist_offer(offer, delivery: nil)
      url = "#{frontend_url}/events/#{offer.event.slug}?waitlist_offer=#{ERB::Util.url_encode(WaitlistCredential.offer(offer))}"
      html = email_wrapper("Waitlist offer") do
        <<~HTML
          <h2 style="color:#1f2937">Your tickets are ready</h2>
          <p style="color:#6b7280">#{offer.quantity} #{h(offer.ticket_type.name)} ticket(s) for #{h(offer.event.title)} are reserved for you.</p>
          <p><a href="#{url}" style="display:inline-block;background:#0e7c7b;color:white;padding:14px 28px;border-radius:10px;text-decoration:none">Claim tickets</a></p>
          <p style="color:#6b7280;font-size:14px">This offer expires #{h(offer.expires_at.iso8601)}.</p>
        HTML
      end
      deliver(to: offer.waitlist_entry.email, subject: safe_subject("Your waitlist offer: #{offer.event.title}"),
        html: html, tag: "waitlist_offer", delivery: delivery, offer_id: offer.id)
    end

    def send_communication_campaign(delivery)
      html = email_wrapper(delivery.metadata.fetch("subject")) do
        <<~HTML
          <h2 style="color:#1f2937">#{h(delivery.metadata.fetch('subject'))}</h2>
          <div style="color:#4b5563;white-space:pre-wrap">#{h(delivery.metadata.fetch('body'))}</div>
        HTML
      end
      deliver(to: delivery.recipient, subject: safe_subject(delivery.metadata.fetch("subject")), html: html,
        tag: "communication_campaign", delivery: delivery, campaign_id: delivery.communication_campaign_id)
    end

    def send_event_reminder(reminder, delivery: nil)
      event = reminder.event
      html = email_wrapper("Event reminder") do
        <<~HTML
          <h2 style="color:#1f2937">#{h(event.title)} is coming up</h2>
          <p style="color:#6b7280">#{h(event.venue_name)} · #{h(event.starts_at.in_time_zone(event.timezone).strftime('%A, %B %-d at %-I:%M %p %Z'))}</p>
          <p><a href="#{frontend_url}/events/#{ERB::Util.url_encode(event.slug)}" style="display:inline-block;background:#0e7c7b;color:white;padding:14px 28px;border-radius:10px;text-decoration:none">View event</a></p>
        HTML
      end
      deliver(to: reminder.user.email, subject: safe_subject("Reminder: #{event.title}"), html: html,
        tag: "event_reminder", delivery: delivery, reminder_id: reminder.id)
    end

    # ── Guest List Notification ─────────────────────────────────────
    def send_guest_list_notification(guest_entry, delivery: nil)
      return unless guest_entry.guest_email.present?

      event = guest_entry.event
      html = build_guest_list_html(guest_entry, event)
      subject = safe_subject("You're on the Guest List - #{event.title}")

      deliver(to: guest_entry.guest_email, subject: subject, html: html, tag: "guest_list", delivery: delivery,
        entry_id: guest_entry.id)
    end

    private

    def create_delivery(order: nil, ticket: nil, event: nil, requested_by: nil, template:, recipient:, metadata: {},
      idempotency_key: nil)
      digest_source = [template, recipient.to_s.downcase, order&.cache_key_with_version,
        ticket&.cache_key_with_version, event&.cache_key_with_version, metadata.to_json].join("|")
      attributes = {
        order: order,
        ticket: ticket,
        event: event,
        requested_by: requested_by,
        channel: "email",
        template: template,
        recipient: recipient.to_s.strip.downcase,
        provider: configured? ? "resend" : "simulated",
        payload_digest: Digest::SHA256.hexdigest(digest_source),
        metadata: metadata,
        status: :queued
      }
      return MessageDelivery.create!(attributes) unless idempotency_key

      MessageDelivery.find_or_create_by!(idempotency_key: idempotency_key) do |delivery|
        delivery.assign_attributes(attributes)
      end
    end

    def record_enqueue_failure(delivery, error)
      delivery&.update(status: :failed, last_error: "#{error.class}: #{error.message}")
    rescue StandardError => tracking_error
      Rails.logger.error("[MessageDelivery] Unable to record enqueue failure: #{tracking_error.class}")
    end

    # ── Unified delivery method ─────────────────────────────────────
    def deliver(to:, subject:, html:, tag: nil, delivery: nil, **log_meta)
      unless configured?
        meta_str = log_meta.map { |k, v| "#{k}=#{v}" }.join(", ")
        Rails.logger.info(
          "[EmailService SIMULATE] Would send to=#{to} subject=\"#{subject}\" tag=#{tag} #{meta_str}"
        )
        return { simulated: true, to: to, subject: subject }
      end

      params = {
        from: FROM_EMAIL,
        to: to,
        subject: subject,
        html: html
      }
      params[:tags] = [{ name: "category", value: tag }] if tag.present?

      options = delivery ? { idempotency_key: delivery.idempotency_key } : {}
      Resend::Emails.send(params, options: options)
    end

    # ── HTML Builders ───────────────────────────────────────────────

    def email_wrapper(title_text, &block)
      content = block.call
      <<~HTML
        <!DOCTYPE html>
        <html>
        <head>
          <meta charset="utf-8">
          <meta name="viewport" content="width=device-width, initial-scale=1.0">
        </head>
        <body style="font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, sans-serif; margin: 0; padding: 20px; background-color: #f9fafb;">
          <div style="max-width: 600px; margin: 0 auto; background: white; border-radius: 12px; overflow: hidden; box-shadow: 0 1px 3px rgba(0,0,0,0.1);">
            <div style="background: linear-gradient(135deg, #0e7c7b 0%, #14a3a1 100%); padding: 28px; text-align: center;">
              <h1 style="color: white; margin: 0; font-size: 26px; font-weight: 700; letter-spacing: -0.5px;">HafaPass</h1>
            </div>
            <div style="padding: 36px 28px;">
              #{content}
            </div>
            <div style="background: #f9fafb; padding: 20px 28px; text-align: center; border-top: 1px solid #e5e7eb;">
              <p style="color: #9ca3af; margin: 0; font-size: 12px;">Powered by HafaPass &middot; Shimizu Technology</p>
            </div>
          </div>
        </body>
        </html>
      HTML
    end

    def build_order_confirmation_html(order, event, tickets)
      ticket_rows = tickets.map do |ticket|
        <<~HTML
          <tr>
            <td style="padding: 10px 14px; border-bottom: 1px solid #e5e7eb;">#{h([ticket.ticket_type.name, ticket.seat_label].compact.join(" — "))}</td>
            <td style="padding: 10px 14px; border-bottom: 1px solid #e5e7eb;">#{h(ticket.attendee_name)}</td>
            <td style="padding: 10px 14px; border-bottom: 1px solid #e5e7eb;">
              <a href="#{ticket_url(ticket)}" style="color: #2563eb; text-decoration: none;">View Ticket</a>
            </td>
          </tr>
        HTML
      end.join

      discount_row = if order.discount_cents > 0
        "<p style=\"color: #059669; margin: 0 0 4px;\">Discount: -$#{format_cents(order.discount_cents)}</p>"
      else
        ""
      end

      email_wrapper("Order Confirmed") do
        <<~HTML
          <h2 style="color: #1f2937; margin: 0 0 8px; font-size: 22px;">Your tickets are confirmed!</h2>
          <p style="color: #6b7280; margin: 0 0 28px;">Thank you for your purchase, #{ERB::Util.html_escape(order.buyer_name)}.</p>

          <div style="background: #f3f4f6; border-radius: 10px; padding: 20px; margin-bottom: 28px;">
            <h3 style="color: #1f2937; margin: 0 0 8px;">#{h(event.title)}</h3>
            <p style="color: #6b7280; margin: 0 0 4px;">#{format_event_date(event)}</p>
            <p style="color: #6b7280; margin: 0;">#{h(event.venue_name)}</p>
          </div>

          <div style="margin-bottom: 28px;">
            <h3 style="color: #1f2937; margin: 0 0 12px;">Order Summary</h3>
            <p style="color: #6b7280; margin: 0 0 4px;">Subtotal: $#{format_cents(order.subtotal_cents)}</p>
            #{discount_row}
            <p style="color: #6b7280; margin: 0 0 4px;">Service Fee: $#{format_cents(order.service_fee_cents)}</p>
            <p style="color: #1f2937; font-weight: 600; margin: 0;"><strong>Total: $#{format_cents(order.total_cents)}</strong></p>
          </div>

          <h3 style="color: #1f2937; margin: 0 0 12px;">Your Tickets</h3>
          <table style="width: 100%; border-collapse: collapse;">
            <thead>
              <tr style="background: #f9fafb;">
                <th style="padding: 10px 14px; text-align: left; color: #6b7280; font-size: 12px; text-transform: uppercase;">Type</th>
                <th style="padding: 10px 14px; text-align: left; color: #6b7280; font-size: 12px; text-transform: uppercase;">Attendee</th>
                <th style="padding: 10px 14px; text-align: left; color: #6b7280; font-size: 12px; text-transform: uppercase;">Ticket</th>
              </tr>
            </thead>
            <tbody>#{ticket_rows}</tbody>
          </table>

          <p style="color: #6b7280; margin: 28px 0 0; font-size: 14px;">
            Present your QR code at the door for entry. You can access your tickets anytime at
            <a href="#{frontend_url}/my-tickets" style="color: #2563eb; text-decoration: none;">hafapass.com/my-tickets</a>.
          </p>
        HTML
      end
    end

    def build_ticket_email_html(ticket, event, ticket_type)
      email_wrapper("Your Ticket") do
        <<~HTML
          <div style="text-align: center;">
            <h2 style="color: #1f2937; margin: 0 0 8px; font-size: 22px;">Your Ticket</h2>
            <p style="color: #6b7280; margin: 0 0 28px;">#{h(event.title)}</p>

            <div style="background: #f3f4f6; border-radius: 10px; padding: 28px; margin-bottom: 28px;">
              <p style="color: #1f2937; font-weight: 600; margin: 0 0 4px;">#{h(ticket_type.name)}</p>
              #{ticket.seat_label ? "<p style=\"color: #1f2937; margin: 0 0 4px;\">#{h(ticket.seat_label)}</p>" : ""}
              <p style="color: #6b7280; margin: 0 0 4px;">#{format_event_date(event)}</p>
              <p style="color: #6b7280; margin: 0;">#{h(event.venue_name)}</p>
            </div>

            <p style="margin: 0 0 20px;">
              <a href="#{ticket_url(ticket)}" style="display: inline-block; background: linear-gradient(135deg, #e85a4f 0%, #d64545 100%); color: white; padding: 14px 32px; border-radius: 10px; text-decoration: none; font-weight: 600; font-size: 16px;">View Your Ticket</a>
            </p>

            <p style="color: #6b7280; font-size: 14px; margin: 0;">Present your QR code at the door for entry.</p>
          </div>
        HTML
      end
    end

    def build_order_recovery_html(order)
      link = order_access_url(order)
      email_wrapper("Order access") do
        <<~HTML
          <h2 style="color: #1f2937; margin: 0 0 8px; font-size: 22px;">Access your HafaPass order</h2>
          <p style="color: #6b7280; margin: 0 0 24px;">Use the secure link below to view the latest payment and ticket status for order #{ERB::Util.html_escape(order.reference)}.</p>
          <p style="margin: 0 0 20px;">
            <a href="#{link}" style="display: inline-block; background: #0e7c7b; color: white; padding: 14px 28px; border-radius: 10px; text-decoration: none; font-weight: 600;">View Order</a>
          </p>
          <p style="color: #6b7280; font-size: 13px; margin: 0;">This link expires in 30 days. Request a new one if it stops working.</p>
        HTML
      end
    end

    def build_refund_notification_html(order, event)
      amount_str = if order.refund_amount_cents >= order.total_cents
        "Full refund"
      else
        "Partial refund ($#{format_cents(order.refund_amount_cents)})"
      end

      email_wrapper("Refund Processed") do
        <<~HTML
          <h2 style="color: #1f2937; margin: 0 0 8px; font-size: 22px;">Refund Processed</h2>
          <p style="color: #6b7280; margin: 0 0 28px;">Your refund for #{h(event.title)} has been processed.</p>

          <div style="background: #f0fdf4; border: 1px solid #bbf7d0; border-radius: 10px; padding: 20px; margin-bottom: 28px;">
            <p style="color: #166534; font-weight: 600; margin: 0 0 8px;">#{amount_str}</p>
            <p style="color: #166534; margin: 0;">$#{format_cents(order.refund_amount_cents)} will be returned to your original payment method within 5-10 business days.</p>
          </div>

          #{order.refund_reason.present? ? "<p style=\"color: #6b7280; margin: 0 0 12px;\"><strong>Reason:</strong> #{ERB::Util.html_escape(order.refund_reason)}</p>" : ""}

          <p style="color: #6b7280; font-size: 14px; margin: 0;">If you have any questions, please contact the event organizer.</p>
        HTML
      end
    end

    def build_guest_list_html(guest_entry, event)
      email_wrapper("Guest List") do
        <<~HTML
          <div style="text-align: center;">
            <h2 style="color: #1f2937; margin: 0 0 8px; font-size: 22px;">You're on the Guest List!</h2>
            <p style="color: #6b7280; margin: 0 0 28px;">#{ERB::Util.html_escape(guest_entry.guest_name)}, you've been added to the guest list for:</p>

            <div style="background: #f3f4f6; border-radius: 10px; padding: 28px; margin-bottom: 28px;">
              <h3 style="color: #1f2937; margin: 0 0 8px;">#{h(event.title)}</h3>
              <p style="color: #6b7280; margin: 0 0 4px;">#{format_event_date(event)}</p>
              <p style="color: #6b7280; margin: 0;">#{h(event.venue_name)}</p>
              <p style="color: #1f2937; font-weight: 600; margin: 12px 0 0;">#{h(guest_entry.ticket_type.name)} x #{guest_entry.quantity}</p>
            </div>

            #{guest_entry.notes.present? ? "<p style=\"color: #6b7280; margin: 0 0 20px;\"><em>#{ERB::Util.html_escape(guest_entry.notes)}</em></p>" : ""}

            <p style="color: #6b7280; font-size: 14px; margin: 0;">Present your name at the door for entry. No ticket purchase required.</p>
          </div>
        HTML
      end
    end

    def build_waitlist_notification_html(entry, event, event_url)
      email_wrapper("Tickets Available") do
        <<~HTML
          <div style="text-align: center;">
            <h2 style="color: #1f2937; margin: 0 0 8px; font-size: 22px;">Tickets Are Available!</h2>
            <p style="color: #6b7280; margin: 0 0 28px;">#{ERB::Util.html_escape(entry.name || 'Hi there')}, great news — tickets are now available for:</p>

            <div style="background: #f3f4f6; border-radius: 10px; padding: 28px; margin-bottom: 28px;">
              <h3 style="color: #1f2937; margin: 0 0 8px;">#{ERB::Util.html_escape(event.title)}</h3>
              <p style="color: #6b7280; margin: 0 0 4px;">#{format_event_date(event)}</p>
              <p style="color: #6b7280; margin: 0;">#{ERB::Util.html_escape(event.venue_name || '')}</p>
            </div>

            <p style="color: #6b7280; margin: 0 0 24px;">You have <strong>24 hours</strong> to purchase your tickets before your spot expires.</p>

            <a href="#{event_url}" style="display: inline-block; background: linear-gradient(135deg, #0e7c7b 0%, #14a3a1 100%); color: white; text-decoration: none; padding: 14px 32px; border-radius: 10px; font-weight: 600; font-size: 16px;">Get Your Tickets</a>
          </div>
        HTML
      end
    end

    def ticket_url(ticket)
      "#{frontend_url}/tickets/#{ticket.display_credential}"
    end

    def order_access_url(order)
      token = order.user_id.nil? ? GuestOrderAccess.issue!(order) : nil
      base = "#{frontend_url}/orders/#{order.id}/confirmation"
      token ? "#{base}?guest_token=#{ERB::Util.url_encode(token)}" : base
    end

    def frontend_url
      ENV.fetch("FRONTEND_URL", "http://localhost:5173")
    end

    def format_event_date(event)
      event.starts_at&.in_time_zone(event.timezone || "Pacific/Guam")&.strftime("%B %d, %Y at %I:%M %p")
    end

    def format_cents(cents)
      format("%.2f", cents / 100.0)
    end

    def h(value)
      ERB::Util.html_escape(value.to_s)
    end

    def safe_subject(value)
      value.to_s.gsub(/[\r\n]+/, " ").strip.first(240)
    end
  end
end
