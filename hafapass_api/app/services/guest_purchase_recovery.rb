# frozen_string_literal: true

class GuestPurchaseRecovery
  def self.call(user:, request: nil)
    emails = ClerkIdentity.verified_email_addresses(user.clerk_id, require_available: true)
    recovered_orders = 0
    recovered_tickets = 0

    Order.where(user_id: nil).where("LOWER(BTRIM(buyer_email)) IN (?)", emails).find_each do |order|
      order.with_lock do
        # Another recovery may have acquired this purchase while we waited.
        next unless order.user_id.nil? && emails.include?(order.buyer_email.strip.downcase)

        order.update!(user: user)
        ticket_count = 0
        order.tickets.where(holder_user_id: nil)
          .where("LOWER(BTRIM(holder_email)) IN (?)", emails).order(:id).lock.each do |ticket|
          # Accepted transfers retain their current holder and credential versions.
          next if ticket.ticket_transfers.accepted.exists?

          ticket.update!(holder_user: user)
          ticket_count += 1
        end
        AuditLogger.record!(action: "guest_purchase.recovered", auditable: order, actor: user,
          organization: order.event.organization, metadata: { recovered_tickets: ticket_count }, request: request)
        recovered_orders += 1
        recovered_tickets += ticket_count
      end
    end

    { recovered_orders_count: recovered_orders, recovered_tickets_count: recovered_tickets }
  end
end
