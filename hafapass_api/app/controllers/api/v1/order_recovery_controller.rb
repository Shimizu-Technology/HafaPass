# frozen_string_literal: true

class Api::V1::OrderRecoveryController < ApplicationController
  skip_before_action :authenticate_user!

  def create
    reference = params[:reference].to_s.strip.upcase
    email = params[:buyer_email].to_s.strip.downcase
    order = Order.where(reference: reference).where("LOWER(buyer_email) = ?", email).first

    queue_recovery(order) if order && order.user_id.nil?

    render json: { message: "If those details match an order, a secure access link has been sent." }, status: :accepted
  end

  private

  def recovery_allowed?(order)
    !order.message_deliveries.where(template: "order_recovery")
      .where(status: [:queued, :sent])
      .where(created_at: 2.minutes.ago..)
      .exists?
  end

  def queue_recovery(order)
    order.with_lock do
      return unless recovery_allowed?(order)

      GuestOrderAccess.issue!(order, rotate: true)
      EmailService.send_order_recovery_async(order)
    end
  rescue StandardError => e
    # Recovery must remain enumeration-safe even when the mail queue is
    # temporarily unavailable. Never expose whether the order matched.
    Rails.logger.error("[OrderRecovery] Unable to queue recovery: #{e.class}")
  end
end
