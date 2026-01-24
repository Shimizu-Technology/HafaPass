# frozen_string_literal: true

class EmailService
  FROM_EMAIL = ENV.fetch("MAILER_FROM_EMAIL", "tickets@hafapass.com")

  class << self
    def configured?
      ENV["RESEND_API_KEY"].present?
    end

    def send_order_confirmation(order)
      unless configured?
        Rails.logger.info("Email would be sent to #{order.buyer_email} (order confirmation ##{order.id})")
        return
      end

      event = order.event
      tickets = order.tickets.includes(:ticket_type)

      html = build_order_confirmation_html(order, event, tickets)

      Resend::Emails.send(
        from: FROM_EMAIL,
        to: order.buyer_email,
        subject: "Your HafaPass Tickets - #{event.title}",
        html: html
      )
    end

    def send_ticket_email(ticket)
      unless configured?
        Rails.logger.info("Email would be sent to #{ticket.attendee_email} (ticket #{ticket.qr_code})")
        return
      end

      event = ticket.event
      ticket_type = ticket.ticket_type

      html = build_ticket_email_html(ticket, event, ticket_type)

      Resend::Emails.send(
        from: FROM_EMAIL,
        to: ticket.attendee_email,
        subject: "Your Ticket - #{event.title}",
        html: html
      )
    end

    private

    def build_order_confirmation_html(order, event, tickets)
      ticket_rows = tickets.map do |ticket|
        <<~HTML
          <tr>
            <td style="padding: 8px 12px; border-bottom: 1px solid #e5e7eb;">#{ticket.ticket_type.name}</td>
            <td style="padding: 8px 12px; border-bottom: 1px solid #e5e7eb;">#{ticket.attendee_name}</td>
            <td style="padding: 8px 12px; border-bottom: 1px solid #e5e7eb;">
              <a href="#{ticket_url(ticket)}" style="color: #2563eb;">View Ticket</a>
            </td>
          </tr>
        HTML
      end.join

      <<~HTML
        <!DOCTYPE html>
        <html>
        <head>
          <meta charset="utf-8">
          <meta name="viewport" content="width=device-width, initial-scale=1.0">
        </head>
        <body style="font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, sans-serif; margin: 0; padding: 20px; background-color: #f9fafb;">
          <div style="max-width: 600px; margin: 0 auto; background: white; border-radius: 8px; overflow: hidden; box-shadow: 0 1px 3px rgba(0,0,0,0.1);">
            <div style="background: #1e3a5f; padding: 24px; text-align: center;">
              <h1 style="color: white; margin: 0; font-size: 24px;">HafaPass</h1>
            </div>
            <div style="padding: 32px 24px;">
              <h2 style="color: #1f2937; margin: 0 0 8px;">Your tickets are confirmed!</h2>
              <p style="color: #6b7280; margin: 0 0 24px;">Thank you for your purchase, #{order.buyer_name}.</p>

              <div style="background: #f3f4f6; border-radius: 8px; padding: 16px; margin-bottom: 24px;">
                <h3 style="color: #1f2937; margin: 0 0 8px;">#{event.title}</h3>
                <p style="color: #6b7280; margin: 0 0 4px;">#{format_event_date(event)}</p>
                <p style="color: #6b7280; margin: 0;">#{event.venue_name}</p>
              </div>

              <div style="margin-bottom: 24px;">
                <h3 style="color: #1f2937; margin: 0 0 12px;">Order Summary</h3>
                <p style="color: #6b7280; margin: 0 0 4px;">Subtotal: $#{format_cents(order.subtotal_cents)}</p>
                <p style="color: #6b7280; margin: 0 0 4px;">Service Fee: $#{format_cents(order.service_fee_cents)}</p>
                <p style="color: #1f2937; font-weight: 600; margin: 0;"><strong>Total: $#{format_cents(order.total_cents)}</strong></p>
              </div>

              <h3 style="color: #1f2937; margin: 0 0 12px;">Your Tickets</h3>
              <table style="width: 100%; border-collapse: collapse;">
                <thead>
                  <tr style="background: #f9fafb;">
                    <th style="padding: 8px 12px; text-align: left; color: #6b7280; font-size: 12px; text-transform: uppercase;">Type</th>
                    <th style="padding: 8px 12px; text-align: left; color: #6b7280; font-size: 12px; text-transform: uppercase;">Attendee</th>
                    <th style="padding: 8px 12px; text-align: left; color: #6b7280; font-size: 12px; text-transform: uppercase;">Ticket</th>
                  </tr>
                </thead>
                <tbody>
                  #{ticket_rows}
                </tbody>
              </table>

              <p style="color: #6b7280; margin: 24px 0 0; font-size: 14px;">
                Present your QR code at the door for entry. You can access your tickets anytime at
                <a href="#{frontend_url}/my-tickets" style="color: #2563eb;">hafapass.com/my-tickets</a>.
              </p>
            </div>
            <div style="background: #f9fafb; padding: 16px 24px; text-align: center; border-top: 1px solid #e5e7eb;">
              <p style="color: #9ca3af; margin: 0; font-size: 12px;">Powered by HafaPass &middot; Shimizu Technology</p>
            </div>
          </div>
        </body>
        </html>
      HTML
    end

    def build_ticket_email_html(ticket, event, ticket_type)
      <<~HTML
        <!DOCTYPE html>
        <html>
        <head>
          <meta charset="utf-8">
          <meta name="viewport" content="width=device-width, initial-scale=1.0">
        </head>
        <body style="font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, sans-serif; margin: 0; padding: 20px; background-color: #f9fafb;">
          <div style="max-width: 600px; margin: 0 auto; background: white; border-radius: 8px; overflow: hidden; box-shadow: 0 1px 3px rgba(0,0,0,0.1);">
            <div style="background: #1e3a5f; padding: 24px; text-align: center;">
              <h1 style="color: white; margin: 0; font-size: 24px;">HafaPass</h1>
            </div>
            <div style="padding: 32px 24px; text-align: center;">
              <h2 style="color: #1f2937; margin: 0 0 8px;">Your Ticket</h2>
              <p style="color: #6b7280; margin: 0 0 24px;">#{event.title}</p>

              <div style="background: #f3f4f6; border-radius: 8px; padding: 24px; margin-bottom: 24px;">
                <p style="color: #1f2937; font-weight: 600; margin: 0 0 4px;">#{ticket_type.name}</p>
                <p style="color: #6b7280; margin: 0 0 4px;">#{format_event_date(event)}</p>
                <p style="color: #6b7280; margin: 0;">#{event.venue_name}</p>
              </div>

              <p style="margin: 0 0 16px;">
                <a href="#{ticket_url(ticket)}" style="display: inline-block; background: #2563eb; color: white; padding: 12px 24px; border-radius: 6px; text-decoration: none; font-weight: 600;">View Your Ticket &amp; QR Code</a>
              </p>

              <p style="color: #6b7280; font-size: 14px; margin: 0;">
                Present your QR code at the door for entry.
              </p>
            </div>
            <div style="background: #f9fafb; padding: 16px 24px; text-align: center; border-top: 1px solid #e5e7eb;">
              <p style="color: #9ca3af; margin: 0; font-size: 12px;">Powered by HafaPass &middot; Shimizu Technology</p>
            </div>
          </div>
        </body>
        </html>
      HTML
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
