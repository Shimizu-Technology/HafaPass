# frozen_string_literal: true

require "digest"

class EmailService
  # Local development and test never send real mail, so a reserved domain is safe.
  LOCAL_FROM_EMAIL = "tickets@example.test"
  class ProviderDisabled < StandardError; end
  class TransportContextChanged < StandardError; end

  class << self
    def configured?
      ProviderRehearsal.email_enabled? || PlatformCapabilities.enabled?("resend_production")
    end

    # The sender is configuration: a deployed environment that can send mail
    # must name a verified MAILER_FROM_EMAIL rather than borrow a default domain.
    def from_email
      configured_from = ENV["MAILER_FROM_EMAIL"].to_s.strip.presence
      return configured_from if configured_from
      raise ProviderDisabled, "MAILER_FROM_EMAIL is required to send email in #{Rails.env}" if !Rails.env.local? && configured?

      LOCAL_FROM_EMAIL
    end

    def transport_context_digest
      credential = Resend.api_key
      credential = credential.call if credential.is_a?(Proc)
      Digest::SHA256.hexdigest(JSON.generate([
        "resend", Digest::SHA256.hexdigest(credential.to_s),
        ENV["PROVIDER_CONFIGURATION_REVISION"].to_s, Resend::Request::BASE_URL
      ]))
    end

    def verify_transport_context!(delivery)
      return if delivery.transport_context_digest.present? &&
        delivery.transport_context_digest == transport_context_digest

      raise TransportContextChanged, "The original email transport context requires reconciliation before retrying"
    end

    # Capture the exact recipient/body once; retries never regenerate access links.
    def prepare_delivery_payload(delivery)
      delivery.preparing_outbound_payload = true
      case delivery.template
      when "order_confirmation", "fulfillment_resend"
        send_order_confirmation(delivery.order, delivery: delivery)
      when "ticket_delivery"
        send_ticket_email(delivery.ticket, delivery: delivery)
      when "order_recovery"
        send_order_recovery(delivery.order, delivery: delivery)
      when "event_change"
        change = EventChange.find(delivery.metadata.fetch("event_change_id"))
        send_event_change_notification(change, delivery.order, delivery: delivery)
      when "refund_notification"
        send_refund_notification(delivery.order, delivery: delivery)
      when "guest_list"
        entry = GuestListEntry.find(delivery.metadata.fetch("guest_list_entry_id"))
        send_guest_list_notification(entry, delivery: delivery)
      when "waitlist_notification"
        entry = WaitlistEntry.find(delivery.metadata.fetch("waitlist_entry_id"))
        send_waitlist_notification(entry, delivery: delivery)
      when "ticket_transfer"
        transfer = TicketTransfer.find(delivery.metadata.fetch("ticket_transfer_id"))
        send_ticket_transfer(transfer, delivery: delivery)
      when "waitlist_offer"
        offer = WaitlistOffer.find(delivery.metadata.fetch("waitlist_offer_id"))
        send_waitlist_offer(offer, delivery: delivery)
      when "communication_campaign"
        send_communication_campaign(delivery)
      when "event_reminder"
        reminder = EventReminder.find(delivery.metadata.fetch("event_reminder_id"))
        send_event_reminder(reminder, delivery: delivery)
      when "verification_request"
        profile = OrganizerProfile.find(delivery.metadata.fetch("organizer_profile_id"))
        send_verification_request(profile, delivery.recipient, delivery: delivery)
      else
        raise ArgumentError, "Unsupported message template"
      end
    ensure
      delivery.preparing_outbound_payload = false
    end

    def send_delivery_payload(delivery)
      if delivery.provider == "simulated"
        raise ProviderDisabled, "Production email cannot simulate a delivery" if Rails.env.production?

        return { simulated: true }
      end
      unless delivery.provider == "resend" && configured?
        raise ProviderDisabled, "The prepared email provider is unavailable"
      end
      verify_transport_context!(delivery)

      deliver_payload(delivery.outbound_payload, delivery: delivery)
    end

    # ── Async Methods (use these from controllers) ──────────────────
    # These enqueue background jobs for better performance

    def send_order_confirmation_async(order, requested_by: nil, template: "order_confirmation")
      delivery = create_delivery(order: order, event: order.event, requested_by: requested_by, template: template,
        recipient: order.buyer_email, idempotency_key: template == "order_confirmation" ? "order-confirmation/#{order.id}" : nil)
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
          recipient: order.buyer_email, metadata: { event_change_id: change.id }, idempotency_key: "event-change/#{change.id}/#{order.id}")
        MessageDeliveryJob.perform_later(delivery.id)
      rescue StandardError => e
        raise unless delivery

        record_enqueue_failure(delivery, e)
        Rails.logger.error(
          "[EventChangeNotification] Unable to queue change=#{change.id} order=#{order.id}: #{e.class}"
        )
      end
    end

    def send_refund_notification_async(order, refund: nil)
      delivery = create_delivery(order: order, event: order.event, template: "refund_notification",
        recipient: order.buyer_email, idempotency_key: refund ? "refund-notification/#{refund.id}" : nil)
      MessageDeliveryJob.perform_later(delivery.id)
      delivery
    end

    def send_guest_list_notification_async(guest_entry)
      return unless guest_entry.guest_email.present?

      delivery = create_delivery(event: guest_entry.event, template: "guest_list", recipient: guest_entry.guest_email,
        metadata: { guest_list_entry_id: guest_entry.id }, idempotency_key: "guest-list/#{guest_entry.id}")
      MessageDeliveryJob.perform_later(delivery.id)
      delivery
    end

    def send_waitlist_notification_async(waitlist_entry)
      return unless waitlist_entry.email.present?

      delivery = create_delivery(event: waitlist_entry.event, template: "waitlist_notification",
        recipient: waitlist_entry.email, metadata: { waitlist_entry_id: waitlist_entry.id },
        idempotency_key: "waitlist-notification/#{waitlist_entry.id}/#{waitlist_entry.notified_at&.iso8601(6)}")
      MessageDeliveryJob.perform_later(delivery.id)
      delivery
    end

    def send_ticket_transfer_async(transfer)
      delivery = create_delivery(ticket: transfer.ticket, order: transfer.ticket.order, event: transfer.ticket.event,
        template: "ticket_transfer", recipient: transfer.recipient_email,
        metadata: { ticket_transfer_id: transfer.id }, idempotency_key: "ticket-transfer/#{transfer.id}")
      MessageDeliveryJob.perform_later(delivery.id)
      delivery
    end

    def send_waitlist_offer_async(offer)
      delivery = create_delivery(event: offer.event, template: "waitlist_offer",
        recipient: offer.waitlist_entry.email, metadata: { waitlist_offer_id: offer.id }, idempotency_key: "waitlist-offer/#{offer.id}")
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

    # Tells every platform administrator an organizer asked to be verified,
    # which is what lets their published events sell in production.
    # Deliveries are stored against an event, so the notice rides on the
    # organizer's latest event. The admin dashboard's verification queue is the
    # source of truth: an organizer with no events yet appears there only.
    def send_verification_request_async(profile)
      requested_at = profile.verification_requested_at || Time.current
      event = profile.events.order(created_at: :desc).first
      return unless event

      admins = User.where(role: :admin).where.not(email: [nil, ""]).order(:id).to_a.uniq { |admin| admin.email.downcase }
      admins.each do |admin|
        delivery = nil
        delivery = create_delivery(event: event, requested_by: profile.user, template: "verification_request",
          recipient: admin.email,
          metadata: { organizer_profile_id: profile.id, requested_at: requested_at.iso8601(6) },
          idempotency_key: "verification-request/#{profile.id}/#{requested_at.to_i}/#{admin.id}")
        MessageDeliveryJob.perform_later(delivery.id)
      rescue StandardError => e
        record_enqueue_failure(delivery, e) if delivery
        Rails.logger.error("[VerificationRequest] Unable to queue profile=#{profile.id}: #{e.class}")
      end
    end

    def send_verification_request(profile, recipient, delivery: nil)
      name = ERB::Util.html_escape(profile.business_name)
      html = <<~HTML
        <div style="font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', sans-serif; max-width: 560px; margin: 0 auto; padding: 24px;">
          <h2 style="color: #1f2937; margin: 0 0 12px; font-size: 20px;">#{name} asked to be verified</h2>
          <p style="color: #4b5563; margin: 0 0 20px;">Verify the organizer on the HåfaPass admin dashboard so their published events can sell tickets.</p>
          <p><a href="#{frontend_url}/admin" style="display:inline-block;background:#0e7c7b;color:white;padding:12px 24px;border-radius:10px;text-decoration:none">Open the admin dashboard</a></p>
        </div>
      HTML
      deliver(to: recipient, subject: safe_subject("Verification requested: #{profile.business_name}"), html: html,
        tag: "verification_request", delivery: delivery, organizer_profile_id: profile.id)
    end

    # ── Order Confirmation ──────────────────────────────────────────
    def send_order_confirmation(order, delivery: nil)
      return send_prepared_direct(delivery) if configured? && !delivery&.preparing_outbound_payload

      event = order.event
      tickets = order.tickets.includes(:ticket_type).reject { |ticket| ticket.transferred_away_from?(order) }
      pdfs = TicketEmailAttachments.plan(tickets)
      html, subject = in_locale(order.locale) do
        [build_order_confirmation_html(order, event, tickets, pdfs: pdfs),
          safe_subject(t("order_confirmation.subject", event: event_title(event)))]
      end

      deliver(to: order.buyer_email, subject: subject, html: html, tag: "order_confirmation", delivery: delivery,
        attachments: pdfs.attachments, order_id: order.id)
    end

    def send_order_recovery(order, delivery: nil)
      return send_prepared_direct(delivery) if configured? && !delivery&.preparing_outbound_payload

      html = build_order_recovery_html(order)
      deliver(
        to: order.buyer_email,
        subject: "Access your HåfaPass order #{order.reference}",
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
      return send_prepared_direct(delivery) if configured? && !delivery&.preparing_outbound_payload

      event = ticket.event
      ticket_type = ticket.ticket_type
      pdfs = TicketEmailAttachments.plan([ticket])
      html, subject = in_locale(ticket.order&.locale) do
        [build_ticket_email_html(ticket, event, ticket_type, pdfs: pdfs),
          safe_subject(t("ticket.subject", event: event_title(event)))]
      end

      deliver(to: ticket.attendee_email, subject: subject, html: html, tag: "ticket_delivery", delivery: delivery,
        attachments: pdfs.attachments, ticket_id: ticket.id)
    end

    # ── Refund Notification ─────────────────────────────────────────
    def send_refund_notification(order, delivery: nil)
      event = order.event
      html, subject = in_locale(order.locale) do
        [build_refund_notification_html(order, event), safe_subject(t("refund.subject", event: event_title(event)))]
      end

      deliver(to: order.buyer_email, subject: subject, html: html, tag: "refund_notification", delivery: delivery,
        order_id: order.id)
    end

    # ── Waitlist Notification ──────────────────────────────────────
    def send_waitlist_notification(waitlist_entry, delivery: nil)
      return unless waitlist_entry.email.present?

      event = waitlist_entry.event
      event_url = "#{frontend_url}/events/#{event.slug}"
      html, subject = in_locale(waitlist_entry.locale) do
        [build_waitlist_notification_html(waitlist_entry, event, event_url),
          safe_subject(t("waitlist.subject", event: event_title(event)))]
      end

      deliver(to: waitlist_entry.email, subject: subject, html: html, tag: "waitlist_notification", delivery: delivery,
        entry_id: waitlist_entry.id)
    end

    def send_ticket_transfer(transfer, delivery: nil)
      url = "#{frontend_url}/ticket-transfers/accept?token=#{ERB::Util.url_encode(TicketTransferCredential.issue(transfer))}"
      event = transfer.ticket.event
      # The recipient's language is unknown (the transfer records the sender's), so English.
      html, subject = in_locale(AppLocale::DEFAULT) do
        body = email_wrapper(t("transfer.title")) do
          <<~HTML
            <h2 style="color:#1f2937">#{ht('transfer.heading')}</h2>
            <p style="color:#6b7280">#{h(event_title(event))} — #{h(ticket_type_name(transfer.ticket.ticket_type))}</p>
            <p><a href="#{url}" style="display:inline-block;background:#0e7c7b;color:white;padding:14px 28px;border-radius:10px;text-decoration:none">#{ht('transfer.accept')}</a></p>
            <p style="color:#6b7280;font-size:14px">#{ht('transfer.sign_in', email: transfer.recipient_email,
              expires_at: format_local_datetime(transfer.expires_at, event.timezone, with_zone: true))}</p>
          HTML
        end
        [body, safe_subject(t("transfer.subject", event: event_title(event)))]
      end
      deliver(to: transfer.recipient_email, subject: subject,
        html: html, tag: "ticket_transfer", delivery: delivery, ticket_id: transfer.ticket_id)
    end

    def send_waitlist_offer(offer, delivery: nil)
      url = "#{frontend_url}/events/#{offer.event.slug}?waitlist_offer=#{ERB::Util.url_encode(WaitlistCredential.offer(offer))}"
      event = offer.event
      html, subject = in_locale(offer.waitlist_entry.locale) do
        body = email_wrapper(t("waitlist_offer.title")) do
          <<~HTML
            <h2 style="color:#1f2937">#{ht('waitlist_offer.heading')}</h2>
            <p style="color:#6b7280">#{ht('waitlist_offer.body', count: offer.quantity,
              ticket_type: ticket_type_name(offer.ticket_type), event: event_title(event))}</p>
            <p><a href="#{url}" style="display:inline-block;background:#0e7c7b;color:white;padding:14px 28px;border-radius:10px;text-decoration:none">#{ht('waitlist_offer.cta')}</a></p>
            <p style="color:#6b7280;font-size:14px">#{ht('waitlist_offer.expires',
              expires_at: format_local_datetime(offer.expires_at, event.timezone, with_zone: true))}</p>
          HTML
        end
        [body, safe_subject(t("waitlist_offer.subject", event: event_title(event)))]
      end
      deliver(to: offer.waitlist_entry.email, subject: subject,
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
        provider: delivery_provider,
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

    def delivery_provider
      return "resend" if configured?
      return "disabled" if Rails.env.production?

      "simulated"
    end

    # ── Unified delivery method ─────────────────────────────────────
    def deliver(to:, subject:, html:, tag: nil, delivery: nil, attachments: nil, **log_meta)
      params = { from: from_email, to: delivery ? delivery.recipient : to, subject: subject, html: html }
      # Ticket PDFs travel as provider-fetched URLs (see TicketEmailAttachments).
      params[:attachments] = attachments if attachments.present?
      reply_to = ENV["MAILER_REPLY_TO"].to_s.strip.presence
      params[:reply_to] = reply_to if reply_to
      params[:subject] = "[HåfaPass TEST] #{subject}" if ProviderRehearsal.enabled?
      params[:tags] = [{ name: "category", value: tag }] if tag.present?
      return params.deep_stringify_keys if delivery&.preparing_outbound_payload

      deliver_payload(params, delivery: delivery)
    end

    def deliver_payload(params, delivery: nil)
      if Rails.env.staging? && configured? && !ProviderRehearsal.email_payload_allowed?(params)
        raise ProviderDisabled, "Staging email is restricted to approved rehearsal recipients"
      end
      unless configured?
        if Rails.env.production? || (delivery&.provider == "resend" && delivery.outbound_payload.present?)
          raise ProviderDisabled, "Production email is disabled until current Resend evidence is approved"
        end
        Rails.logger.info("[EmailService SIMULATE] delivery=#{delivery&.id} template=#{delivery&.template}")
        return { simulated: true }
      end

      raise MessageWirePayload::Unavailable, "Real email requires a durable MessageDelivery attempt" unless delivery

      options = { idempotency_key: delivery.idempotency_key }
      verify_transport_context!(delivery)
      params = MessageWirePayload.for_delivery(delivery)
      Resend::Emails.send(params, options: options)
    end

    def send_prepared_direct(delivery)
      raise MessageWirePayload::Unavailable, "Real email requires a durable MessageDelivery attempt" unless delivery

      send_delivery_payload(delivery)
    end

    # ── HTML Builders ───────────────────────────────────────────────

    def email_wrapper(title_text, &block)
      content = block.call
      <<~HTML
        <!DOCTYPE html>
        <html lang="#{I18n.locale}">
        <head>
          <meta charset="utf-8">
          <meta name="viewport" content="width=device-width, initial-scale=1.0">
        </head>
        <body style="font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, sans-serif; margin: 0; padding: 20px; background-color: #f9fafb;">
          <div style="max-width: 600px; margin: 0 auto; background: white; border-radius: 12px; overflow: hidden; box-shadow: 0 1px 3px rgba(0,0,0,0.1);">
            <div style="background: linear-gradient(135deg, #0e7c7b 0%, #14a3a1 100%); padding: 28px; text-align: center;">
              <h1 style="color: white; margin: 0; font-size: 26px; font-weight: 700; letter-spacing: -0.5px;">HåfaPass</h1>
            </div>
            <div style="padding: 36px 28px;">
              #{content}
            </div>
            <div style="background: #f9fafb; padding: 20px 28px; text-align: center; border-top: 1px solid #e5e7eb;">
              <p style="color: #9ca3af; margin: 0; font-size: 12px;">#{ht('footer')}</p>
            </div>
          </div>
        </body>
        </html>
      HTML
    end

    def build_order_confirmation_html(order, event, tickets, pdfs: nil)
      ticket_rows = tickets.map do |ticket|
        <<~HTML
          <tr>
            <td style="padding: 10px 14px; border-bottom: 1px solid #e5e7eb;">#{h([ticket_type_name(ticket.ticket_type), ticket.seat_label].compact.join(" — "))}</td>
            <td style="padding: 10px 14px; border-bottom: 1px solid #e5e7eb;">#{h(ticket.attendee_name)}</td>
            <td style="padding: 10px 14px; border-bottom: 1px solid #e5e7eb;">
              <a href="#{ticket_url(ticket)}" style="color: #2563eb; text-decoration: none;">#{ht('order_confirmation.view_ticket')}</a>
            </td>
          </tr>
        HTML
      end.join

      discount_row = if order.discount_cents > 0
        "<p style=\"color: #059669; margin: 0 0 4px;\">#{ht('order_confirmation.discount', amount: money(order.discount_cents))}</p>"
      else
        ""
      end
      my_tickets_link = %(<a href="#{frontend_url}/my-tickets" style="color: #2563eb; text-decoration: none;">#{ht('my_tickets')}</a>)
      header_style = "padding: 10px 14px; text-align: left; color: #6b7280; font-size: 12px; text-transform: uppercase;"

      # A buyer who transferred every ticket gets no empty table or entry instructions.
      tickets_section = if tickets.empty?
        <<~HTML
          <p style="color: #6b7280; margin: 0; font-size: 14px;">
            #{ht('order_confirmation.all_transferred', links: { my_tickets_link: my_tickets_link })}
          </p>
        HTML
      else
        <<~HTML
          <h3 style="color: #1f2937; margin: 0 0 12px;">#{ht('order_confirmation.tickets_heading')}</h3>
          <table style="width: 100%; border-collapse: collapse;">
            <thead>
              <tr style="background: #f9fafb;">
                <th style="#{header_style}">#{ht('order_confirmation.type_column')}</th>
                <th style="#{header_style}">#{ht('order_confirmation.attendee_column')}</th>
                <th style="#{header_style}">#{ht('order_confirmation.ticket_column')}</th>
              </tr>
            </thead>
            <tbody>#{ticket_rows}</tbody>
          </table>

          <p style="color: #6b7280; margin: 28px 0 0; font-size: 14px;">
            #{ht('order_confirmation.entry_instructions', links: { my_tickets_link: my_tickets_link })}
          </p>
          #{pdf_attachment_note(pdfs)}
        HTML
      end

      seller = SellerIdentity.for_event(event)
      email_wrapper(t("order_confirmation.title")) do
        <<~HTML
          <h2 style="color: #1f2937; margin: 0 0 8px; font-size: 22px;">#{ht('order_confirmation.heading')}</h2>
          <p style="color: #6b7280; margin: 0 0 28px;">#{ht('order_confirmation.thanks', name: order.buyer_name)}</p>

          <div style="background: #f3f4f6; border-radius: 10px; padding: 20px; margin-bottom: 28px;">
            <h3 style="color: #1f2937; margin: 0 0 8px;">#{h(event_title(event))}</h3>
            <p style="color: #6b7280; margin: 0 0 4px;">#{h(format_event_date(event))}</p>
            <p style="color: #6b7280; margin: 0 0 8px;">#{h(event.venue_name)}</p>
            <p style="color: #6b7280; margin: 0; font-size: 13px;">#{h(seller.line)}</p>
          </div>

          <div style="margin-bottom: 28px;">
            <h3 style="color: #1f2937; margin: 0 0 12px;">#{ht('order_confirmation.summary')}</h3>
            <p style="color: #6b7280; margin: 0 0 4px;">#{ht('order_confirmation.reference', reference: order.reference)}</p>
            <p style="color: #6b7280; margin: 0 0 4px;">#{ht('order_confirmation.subtotal', amount: money(order.subtotal_cents))}</p>
            #{discount_row}
            <p style="color: #6b7280; margin: 0 0 4px;">#{ht('order_confirmation.service_fee', amount: money(order.service_fee_cents))}</p>
            <p style="color: #1f2937; font-weight: 600; margin: 0;"><strong>#{ht('order_confirmation.total', amount: money(order.total_cents))}</strong></p>
            <p style="color: #9ca3af; margin: 12px 0 0; font-size: 12px; line-height: 1.5;">
              #{ht('order_confirmation.seller_disclosure', seller: seller.seller_name, service: seller.ticketing_service,
                operator: seller.operator_name)}
            </p>
          </div>

          #{tickets_section}
        HTML
      end
    end

    def build_ticket_email_html(ticket, event, ticket_type, pdfs: nil)
      email_wrapper(t("ticket.heading")) do
        <<~HTML
          <div style="text-align: center;">
            <h2 style="color: #1f2937; margin: 0 0 8px; font-size: 22px;">#{ht('ticket.heading')}</h2>
            <p style="color: #6b7280; margin: 0 0 28px;">#{h(event_title(event))}</p>

            <div style="background: #f3f4f6; border-radius: 10px; padding: 28px; margin-bottom: 28px;">
              <p style="color: #1f2937; font-weight: 600; margin: 0 0 4px;">#{h(ticket_type_name(ticket_type))}</p>
              #{ticket.seat_label ? "<p style=\"color: #1f2937; margin: 0 0 4px;\">#{h(ticket.seat_label)}</p>" : ""}
              <p style="color: #6b7280; margin: 0 0 4px;">#{h(format_event_date(event))}</p>
              <p style="color: #6b7280; margin: 0;">#{h(event.venue_name)}</p>
            </div>

            <p style="margin: 0 0 20px;">
              <a href="#{ticket_url(ticket)}" style="display: inline-block; background: linear-gradient(135deg, #e85a4f 0%, #d64545 100%); color: white; padding: 14px 32px; border-radius: 10px; text-decoration: none; font-weight: 600; font-size: 16px;">#{ht('ticket.view')}</a>
            </p>

            <p style="color: #6b7280; font-size: 14px; margin: 0;">#{ht('ticket.entry_instructions')}</p>
            <p style="color: #9ca3af; font-size: 12px; margin: 16px 0 0;">#{h(SellerIdentity.for_event(event).line)}</p>
            #{pdf_attachment_note(pdfs)}
          </div>
        HTML
      end
    end

    def build_order_recovery_html(order)
      link = order_access_url(order)
      email_wrapper("Order access") do
        <<~HTML
          <h2 style="color: #1f2937; margin: 0 0 8px; font-size: 22px;">Access your HåfaPass order</h2>
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
        t("refund.full")
      else
        t("refund.partial", amount: money(order.refund_amount_cents))
      end
      reason = if order.refund_reason.present?
        "<p style=\"color: #6b7280; margin: 0 0 12px;\"><strong>#{ht('refund.reason')}</strong> #{h(order.refund_reason)}</p>"
      else
        ""
      end

      email_wrapper(t("refund.heading")) do
        <<~HTML
          <h2 style="color: #1f2937; margin: 0 0 8px; font-size: 22px;">#{ht('refund.heading')}</h2>
          <p style="color: #6b7280; margin: 0 0 28px;">#{ht('refund.body', event: event_title(event))}</p>

          <div style="background: #f0fdf4; border: 1px solid #bbf7d0; border-radius: 10px; padding: 20px; margin-bottom: 28px;">
            <p style="color: #166534; font-weight: 600; margin: 0 0 8px;">#{h(amount_str)}</p>
            <p style="color: #166534; margin: 0;">#{ht('refund.returned', amount: money(order.refund_amount_cents))}</p>
          </div>

          #{reason}

          <p style="color: #6b7280; font-size: 14px; margin: 0;">#{ht('refund.questions')}</p>
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
      greeting = entry.name.present? ? ht("waitlist.greeting", name: entry.name) : ht("waitlist.greeting_anonymous")
      email_wrapper(t("waitlist.title")) do
        <<~HTML
          <div style="text-align: center;">
            <h2 style="color: #1f2937; margin: 0 0 8px; font-size: 22px;">#{ht('waitlist.heading')}</h2>
            <p style="color: #6b7280; margin: 0 0 28px;">#{greeting}</p>

            <div style="background: #f3f4f6; border-radius: 10px; padding: 28px; margin-bottom: 28px;">
              <h3 style="color: #1f2937; margin: 0 0 8px;">#{h(event_title(event))}</h3>
              <p style="color: #6b7280; margin: 0 0 4px;">#{h(format_event_date(event))}</p>
              <p style="color: #6b7280; margin: 0;">#{h(event.venue_name)}</p>
            </div>

            <p style="color: #6b7280; margin: 0 0 24px;">#{ht('waitlist.deadline')}</p>

            <a href="#{event_url}" style="display: inline-block; background: linear-gradient(135deg, #0e7c7b 0%, #14a3a1 100%); color: white; text-decoration: none; padding: 14px 32px; border-radius: 10px; font-weight: 600; font-size: 16px;">#{ht('waitlist.cta')}</a>
          </div>
        HTML
      end
    end

    # Worded from what was actually attached: everything, the first few of a
    # large order, or only the tickets that can be used right now.
    def pdf_attachment_note(pdfs)
      return "" unless pdfs&.any?

      count = pdfs.attachments.length
      text = if pdfs.complete?
        count == 1 ? t("pdf_note.single") : t("pdf_note.all", count: count)
      elsif pdfs.capped?
        t("pdf_note.capped", count: count)
      else
        t("pdf_note.partial", count: count, total: pdfs.ticket_count)
      end
      %(<p style="color: #6b7280; margin: 12px 0 0; font-size: 14px;">#{h(text)}</p>)
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
      PublicSiteUrl.frontend
    end

    def format_event_date(event)
      format_local_datetime(event.starts_at, event.timezone)
    end

    # "October 5, 2026 at 7:00 PM" in English; word order, month names and
    # AM/PM come from the email copy of the current language. Deadlines add
    # the zone ("ChST") so a buyer elsewhere is not misled.
    def format_local_datetime(time, zone, with_zone: false)
      return nil unless time

      local = time.in_time_zone(zone.presence || "Pacific/Guam")
      text = I18n.t("emails.formats.event_datetime",
        month_name: Array(I18n.t("emails.formats.month_names"))[local.month - 1], day: local.day,
        year: local.year, hour: local.strftime("%-I"), minute: local.strftime("%M"),
        meridiem: I18n.t(local.hour < 12 ? "emails.formats.am" : "emails.formats.pm"))
      with_zone ? "#{text} #{local.strftime('%Z')}" : text
    end

    # Buyer emails are written in the language recorded on the order, waitlist
    # entry or transfer; anything else is English.
    def in_locale(locale, &)
      I18n.with_locale(AppLocale.i18n_locale(locale), &)
    end

    def t(key, **values)
      I18n.t("emails.#{key}", **values)
    end

    # Escaped copy; `links` fills %{placeholders} with trusted HTML after escaping.
    def ht(key, links: {}, **values)
      tokens = links.keys.each_with_index.to_h { |name, index| [name, "LINKTOKEN#{index}X"] }
      text = h(t(key, **values, **tokens))
      tokens.each { |name, token| text = text.sub(token, links.fetch(name)) }
      text
    end

    def event_title(event)
      event.content_for(I18n.locale)[:title]
    end

    # Issued tickets (emails, PDFs, My Tickets, door lists) all use the
    # organizer's own ticket names so buyers and door staff see the same words.
    def ticket_type_name(ticket_type)
      ticket_type.name
    end

    def money(cents)
      "$#{format_cents(cents)}"
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
