# frozen_string_literal: true

module TicketTransfers
  class Manager
    class TransferError < StandardError; end

    class << self
      def create!(ticket:, recipient_email:, recipient_name: nil, initiated_by: nil)
        transfer = nil
        Ticket.transaction do
          ticket.lock!
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
            expires_at: [7.days.from_now, ticket.event.starts_at].compact.min
          )
        end
        EmailService.send_ticket_transfer_async(transfer)
        transfer
      rescue ActiveRecord::RecordNotUnique
        raise TransferError, "This ticket already has a pending transfer"
      end

      def accept!(token:, user:)
        transfer = TicketTransferCredential.find(token)
        raise TransferError, "Transfer link is invalid or expired" unless transfer

        TicketTransfer.transaction do
          transfer.lock!
          transfer.ticket.lock!
          raise TransferError, "Transfer is no longer available" unless transfer.active?
          unless transfer.recipient_email.casecmp?(user.email.to_s.strip)
            raise TransferError, "Sign in with the email address that received this transfer"
          end
          validate_transferable!(transfer.ticket)

          transfer.ticket.update!(
            holder_user: user,
            holder_email: transfer.recipient_email,
            attendee_name: transfer.recipient_name.presence ||
              [user.first_name, user.last_name].compact.join(" ").presence || transfer.ticket.attendee_name,
            attendee_email: transfer.recipient_email,
            display_credential_version: transfer.ticket.display_credential_version + 1,
            scan_credential_version: transfer.ticket.scan_credential_version + 1
          )
          transfer.update!(status: :accepted, accepted_by_user: user, accepted_at: Time.current,
            token_version: transfer.token_version + 1)
        end
        transfer
      end

      def cancel!(transfer)
        transfer.with_lock do
          raise TransferError, "Only pending transfers can be cancelled" unless transfer.pending?

          transfer.update!(status: :cancelled, cancelled_at: Time.current, token_version: transfer.token_version + 1)
        end
        transfer
      end

      private

      def validate_transferable!(ticket)
        raise TransferError, "Only unused active tickets can be transferred" unless ticket.issued?
        raise TransferError, "Transfers are disabled for this event" unless ticket.event.transfers_enabled?
        raise TransferError, "Transfers close when the event starts" unless ticket.event.starts_at&.future?
        raise TransferError, "Ticket access is blocked" if ticket.order.ticket_access_blocked?
      end
    end
  end
end
