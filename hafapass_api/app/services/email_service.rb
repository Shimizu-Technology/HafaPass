# frozen_string_literal: true

class EmailService
  FROM_EMAIL = ENV.fetch("MAILER_FROM_EMAIL", "tickets@hafapass.com")

  class << self
    def configured?
      ENV["RESEND_API_KEY"].present?
    end

    # ── Async Methods (use these from controllers) ──────────────────
    # These enqueue background jobs for better performance

    def send_order_confirmation_async(order)
      SendOrderConfirmationJob.perform_later(order.id)
    end

    def send_ticket_email_async(ticket)
      SendTicketEmailJob.perform_later(ticket.id)
    end

    def send_refund_notification_async(order)
      SendRefundNotificationJob.perform_later(order.id)
    end

    def send_guest_list_notification_async(guest_entry)
      SendGuestListNotificationJob.perform_later(guest_entry.id)
    end

    def send_waitlist_notification_async(waitlist_entry)
      SendWaitlistNotificationJob.perform_later(waitlist_entry.id)
    end

    # ── Order Confirmation ──────────────────────────────────────────
    def send_order_confirmation(order)
      event = order.event
      tickets = order.tickets.includes(:ticket_type)
      html = build_order_confirmation_html(order, event, tickets)
      subject = "Your HafaPass Tickets - #{event.title}"

      deliver(to: order.buyer_email, subject: subject, html: html, tag: "order_confirmation", order_id: order.id)
    end

    # ── Individual Ticket Email ─────────────────────────────────────
    def send_ticket_email(ticket)
      event = ticket.event
      ticket_type = ticket.ticket_type
      html = build_ticket_email_html(ticket, event, ticket_type)
      subject = "Your Ticket - #{event.title}"

      deliver(to: ticket.attendee_email, subject: subject, html: html, tag: "ticket_delivery", ticket_qr: ticket.qr_code)
    end

    # ── Refund Notification ─────────────────────────────────────────
    def send_refund_notification(order)
      event = order.event
      html = build_refund_notification_html(order, event)
      subject = "Refund Processed - #{event.title}"

      deliver(to: order.buyer_email, subject: subject, html: html, tag: "refund_notification", order_id: order.id)
    end

    # ── Waitlist Notification ──────────────────────────────────────
    def send_waitlist_notification(waitlist_entry)
      return unless waitlist_entry.email.present?

      event = waitlist_entry.event
      frontend_url = ENV.fetch("FRONTEND_URL", "http://localhost:5173")
      event_url = "#{frontend_url}/events/#{event.slug}"
      html = build_waitlist_notification_html(waitlist_entry, event, event_url)
      subject = "Tickets Available - #{event.title}"

      deliver(to: waitlist_entry.email, subject: subject, html: html, tag: "waitlist_notification", entry_id: waitlist_entry.id)
    end

    # ── Guest List Notification ─────────────────────────────────────
    def send_guest_list_notification(guest_entry)
      return unless guest_entry.guest_email.present?

      event = guest_entry.event
      html = build_guest_list_html(guest_entry, event)
      subject = "You're on the Guest List - #{event.title}"

      deliver(to: guest_entry.guest_email, subject: subject, html: html, tag: "guest_list", entry_id: guest_entry.id)
    end

    private

    # ── Unified delivery method ─────────────────────────────────────
    def deliver(to:, subject:, html:, tag: nil, **log_meta)
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

      Resend::Emails.send(params)
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
            <td style="padding: 10px 14px; border-bottom: 1px solid #e5e7eb;">#{ticket.ticket_type.name}</td>
            <td style="padding: 10px 14px; border-bottom: 1px solid #e5e7eb;">#{ticket.attendee_name}</td>
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
            <h3 style="color: #1f2937; margin: 0 0 8px;">#{event.title}</h3>
            <p style="color: #6b7280; margin: 0 0 4px;">#{format_event_date(event)}</p>
            <p style="color: #6b7280; margin: 0;">#{event.venue_name}</p>
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
            <p style="color: #6b7280; margin: 0 0 28px;">#{event.title}</p>

            <div style="background: #f3f4f6; border-radius: 10px; padding: 28px; margin-bottom: 28px;">
              <p style="color: #1f2937; font-weight: 600; margin: 0 0 4px;">#{ticket_type.name}</p>
              <p style="color: #6b7280; margin: 0 0 4px;">#{format_event_date(event)}</p>
              <p style="color: #6b7280; margin: 0;">#{event.venue_name}</p>
            </div>

            <p style="margin: 0 0 20px;">
              <a href="#{ticket_url(ticket)}" style="display: inline-block; background: linear-gradient(135deg, #e85a4f 0%, #d64545 100%); color: white; padding: 14px 32px; border-radius: 10px; text-decoration: none; font-weight: 600; font-size: 16px;">View Your Ticket</a>
            </p>

            <p style="color: #6b7280; font-size: 14px; margin: 0;">Present your QR code at the door for entry.</p>
          </div>
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
          <p style="color: #6b7280; margin: 0 0 28px;">Your refund for #{event.title} has been processed.</p>

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
              <h3 style="color: #1f2937; margin: 0 0 8px;">#{event.title}</h3>
              <p style="color: #6b7280; margin: 0 0 4px;">#{format_event_date(event)}</p>
              <p style="color: #6b7280; margin: 0;">#{event.venue_name}</p>
              <p style="color: #1f2937; font-weight: 600; margin: 12px 0 0;">#{guest_entry.ticket_type.name} x #{guest_entry.quantity}</p>
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
      "#{frontend_url}/tickets/#{ticket.qr_code}"
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
  end
end
