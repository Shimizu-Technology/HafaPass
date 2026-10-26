# frozen_string_literal: true

module TicketTransfers
  class Manager
    class TransferError < StandardError; end

    class << self
      def create!(ticket:, recipient_email:, recipient_name: nil, initiated_by: nil, locale: AppLocale::DEFAULT)
        transfer = nil
        expected_holder_id = ticket.holder_user_id
        ticket.with_entry_lock do
          validate_holder!(ticket, initiated_by, expected_holder_id)
          validate_transferable!(ticket)
          normalized = recipient_email.to_s.strip.downcase
          raise TransferError, "Enter a valid recipient email" unless normalized.match?(URI::MailTo::EMAIL_REGEXP)
          if normalized.casecmp?(ticket.holder_email.to_s)
            raise TransferError, "Recipient must be different from the current ticket holder"
          end

          existing = ticket.ticket_transfers.pending.lock.first
          if existing && !existing.active?
            existing.update!(status: :expired, token_version: existing.token_version + 1)
            existing = nil
          end
          if existing
            raise TransferError, "This ticket already has a pending transfer" unless existing.recipient_email == normalized

            transfer = existing
            next
          end

          transfer = ticket.ticket_transfers.create!(
            initiated_by_user: initiated_by,
            recipient_email: normalized,
            recipient_name: recipient_name,
            locale: locale,
            expires_at: [7.days.from_now, ticket.event.starts_at].compact.min
          )
          audit_seat!(ticket, "seat.transfer_started", initiated_by,
            recipient_email: normalized, ticket_transfer_id: transfer.id)
          EmailService.send_ticket_transfer_async(transfer)
        end
        transfer
      rescue ActiveRecord::RecordNotUnique
        raise TransferError, "This ticket already has a pending transfer"
      end

      def accept!(token:, user:)
        transfer = TicketTransferCredential.find(token)
        raise TransferError, "Transfer link is invalid or expired" unless transfer

        transfer.ticket.with_entry_lock do
          transfer.lock!
          unless TicketTransferCredential.find(token)&.id == transfer.id
            raise TransferError, "Transfer link is invalid or expired"
          end
          raise TransferError, "Transfer is no longer available" unless transfer.active?
          unless ClerkIdentity.email_matches?(user: user, email: transfer.recipient_email)
            raise TransferError, "Sign in with the verified email address that received this transfer and try again"
          end
          validate_transferable!(transfer.ticket)

          AuditContext.set(actor: user) do
            transfer.ticket.update!(
              holder_user: user,
              holder_email: transfer.recipient_email,
              attendee_name: transfer.recipient_name.presence ||
                [user.first_name, user.last_name].compact.join(" ").presence || transfer.ticket.attendee_name,
              attendee_email: transfer.recipient_email,
              display_credential_version: transfer.ticket.display_credential_version + 1,
              scan_credential_version: transfer.ticket.scan_credential_version + 1
            )
          end
          transfer.update!(status: :accepted, accepted_by_user: user, accepted_at: Time.current,
            token_version: transfer.token_version + 1)
          audit_seat!(transfer.ticket, "seat.transfer_accepted", user, ticket_transfer_id: transfer.id)
        end
        transfer
      end

      def cancel!(transfer, initiated_by: nil)
        expected_holder_id = transfer.ticket.holder_user_id
        transfer.ticket.with_entry_lock do
          transfer.lock!
          validate_holder!(transfer.ticket, initiated_by, expected_holder_id)
          raise TransferError, "Only pending transfers can be cancelled" unless transfer.pending?

          transfer.update!(status: :cancelled, cancelled_at: Time.current, token_version: transfer.token_version + 1)
          audit_seat!(transfer.ticket, "seat.transfer_cancelled", nil, ticket_transfer_id: transfer.id)
        end
        transfer
      end

      def expire!(transfer, at: Time.current)
        transfer.ticket.with_entry_lock do
          transfer.lock!
          if transfer.pending? && transfer.expires_at <= at
            transfer.update!(status: :expired, token_version: transfer.token_version + 1)
          end
        end
        transfer
      end

      private

      def validate_holder!(ticket, user, expected_holder_id)
        # Internal callers may omit an actor; even then a lock wait cannot
        # silently authorize a different holder from the one they observed.
        if ticket.holder_user_id != expected_holder_id ||
            (user && ticket.holder_user_id.present? && ticket.holder_user_id != user.id)
          raise TransferError, "This ticket belongs to its current holder"
        end
      end

      def audit_seat!(ticket, action, actor, metadata = {})
        return unless ticket.event_seat

        Seating::Audit.record!(event: ticket.event, action: action, event_seat: ticket.event_seat,
          ticket: ticket, actor: actor, metadata: metadata)
      end

      def validate_transferable!(ticket)
        raise TransferError, "Only unused active tickets can be transferred" unless ticket.issued?
        raise TransferError, "Transfers are disabled for this event" unless ticket.event.transfers_available?
        raise TransferError, "Transfers close when the event starts" unless ticket.event.starts_at&.future?
        raise TransferError, "Ticket access is blocked" if ticket.order.ticket_access_blocked?
      end
    end
  end
end
