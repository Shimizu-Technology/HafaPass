# frozen_string_literal: true

class FulfillmentResender
  COOLDOWN = 2.minutes

  class ResendError < StandardError; end
  class NotAvailable < ResendError; end
  class Cooldown < ResendError; end
  class Unconfirmed < ResendError; end

  def self.call(order:, requested_by: nil)
    unless order.completed? || order.partially_refunded?
      raise NotAvailable, "Tickets are not available for this order"
    end

    order.with_lock do
      if order.message_deliveries.ticket_email.unconfirmed_provider_result.exists?
        raise Unconfirmed, "A previous ticket email has an unconfirmed outcome. Check its status or contact support before requesting another email"
      end

      recent = order.message_deliveries.where(channel: "email", template: "fulfillment_resend")
        .where(created_at: COOLDOWN.ago..)
        .exists?
      raise Cooldown, "A ticket email was requested recently. Please wait two minutes before requesting another" if recent

      EmailService.send_order_confirmation_async(order, requested_by: requested_by, template: "fulfillment_resend")
    end
  end
end
