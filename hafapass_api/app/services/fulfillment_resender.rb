# frozen_string_literal: true

class FulfillmentResender
  COOLDOWN = 2.minutes

  class ResendError < StandardError; end
  class NotAvailable < ResendError; end
  class Cooldown < ResendError; end

  def self.call(order:, requested_by: nil)
    unless order.completed? || order.partially_refunded?
      raise NotAvailable, "Tickets are not available for this order"
    end

    order.with_lock do
      recent = order.message_deliveries.where(template: "fulfillment_resend")
        .where(status: [:queued, :sent])
        .where(created_at: COOLDOWN.ago..)
        .exists?
      raise Cooldown, "Tickets were just sent. Please wait before trying again" if recent

      EmailService.send_order_confirmation_async(order, requested_by: requested_by, template: "fulfillment_resend")
    end
  end
end
