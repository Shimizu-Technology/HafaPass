# frozen_string_literal: true

module Commerce
  class OrderLifecycle
    class InvalidTransition < StandardError; end

    class << self
      def complete!(order, payment: nil, webhook_event: nil, provider_amount_cents: nil, provider_currency: nil, wallet_type: nil)
        completed_now = false

        Order.transaction do
          order.lock!
          payment&.lock!

          if payment && !provider_matches?(payment, provider_amount_cents, provider_currency)
            record_provider_mismatch!(order, payment, webhook_event, provider_amount_cents, provider_currency)
            next
          end

          if order.completed? || order.partially_refunded? || order.refunded?
            mark_payment_succeeded!(payment)
            next
          end

          unless order.pending?
            mark_payment_succeeded!(payment)
            ReconciliationException.create!(
              order: order,
              payment: payment,
              webhook_event: webhook_event,
              code: "late_payment_success_after_inventory_release",
              details: { order_status: order.status }
            )
            next
          end

          holds = order.inventory_holds.order(:id).lock.to_a
          catalog_holds = order.catalog_item_holds.order(:id).lock.to_a
          if holds.empty? || (holds + catalog_holds).any? { |hold| !hold.active? || hold.expires_at <= Time.current }
            release_locked_order!(order, reason: "payment_succeeded_after_hold_expiry", expired: true)
            mark_payment_succeeded!(payment)
            ReconciliationException.create!(
              order: order,
              payment: payment,
              webhook_event: webhook_event,
              code: "late_payment_success_after_hold_expiry"
            )
            next
          end

          holds.each do |hold|
            hold.ticket_type.lock!
            hold.ticket_type.increment!(:quantity_sold, hold.quantity)
            if hold.pricing_tier
              hold.pricing_tier.lock!
              hold.pricing_tier.increment!(:quantity_sold, hold.quantity)
            end
            hold.consume!
          end

          catalog_holds.each do |hold|
            hold.catalog_item.lock!
            hold.catalog_item.increment!(:quantity_sold, hold.quantity)
            hold.consume!
          end

          issue_tickets!(order)
          finalize_promo!(order)
          finalize_waitlist_offer!(order)
          record_promoter_commission!(order)
          mark_payment_succeeded!(payment)
          order.update!(status: :completed, completed_at: Time.current, expires_at: nil, wallet_type: wallet_type)
          record_marketplace_purchase!(order)
          completed_now = true
        end

        if completed_now
          EmailService.send_order_confirmation_async(order)
        end

        completed_now ? :completed : :unchanged
      end

      def fail!(order, payment: nil, failure_code: nil, failure_message: nil, reason: "payment_failed")
        Order.transaction do
          order.lock!
          payment&.lock!
          payment&.update!(
            status: :failed,
            failed_at: Time.current,
            failure_code: failure_code,
            failure_message: failure_message
          ) unless payment&.succeeded?
          release_locked_order!(order, reason: reason) if order.pending?
        end
      end

      def cancel!(order, reason: "buyer_cancelled")
        payments_to_cancel = []
        Order.transaction do
          order.lock!
          raise InvalidTransition, "Only pending orders can be cancelled" unless order.pending?

          release_locked_order!(order, reason: reason)
          payments_to_cancel = order.payments.pending.where(provider: "stripe").to_a
          order.payments.pending.update_all(status: Payment.statuses[:cancelled], updated_at: Time.current)
        end
        cancel_provider_payments!(order, payments_to_cancel)
      end

      def expire!(order, at: Time.current)
        payments_to_cancel = []
        expired_now = false
        Order.transaction do
          order.lock!
          return false unless order.pending? && order.expires_at.present? && order.expires_at <= at

          release_locked_order!(order, reason: "hold_expired", expired: true, at: at)
          payments_to_cancel = order.payments.pending.where(provider: "stripe").to_a
          order.payments.pending.update_all(status: Payment.statuses[:cancelled], updated_at: at)
          expired_now = true
        end
        cancel_provider_payments!(order, payments_to_cancel)
        expired_now
      end

      private

      def provider_matches?(payment, amount_cents, currency)
        amount_matches = amount_cents.nil? || payment.amount_cents == amount_cents.to_i
        currency_matches = currency.nil? || payment.currency.casecmp?(currency.to_s)
        amount_matches && currency_matches
      end

      def record_provider_mismatch!(order, payment, webhook_event, amount_cents, currency)
        code = payment.amount_cents == amount_cents.to_i ? "payment_currency_mismatch" : "payment_amount_mismatch"
        ReconciliationException.create!(
          order: order,
          payment: payment,
          webhook_event: webhook_event,
          code: code,
          expected_amount_cents: payment.amount_cents,
          actual_amount_cents: amount_cents,
          expected_currency: payment.currency,
          actual_currency: currency
        )
      end

      def mark_payment_succeeded!(payment)
        return unless payment

        payment.update!(status: :succeeded, succeeded_at: payment.succeeded_at || Time.current)
      end

      def release_locked_order!(order, reason:, expired: false, at: Time.current)
        order.inventory_holds.active.order(:id).lock.each do |hold|
          hold.release!(reason: reason, expired: expired, at: at)
        end
        order.catalog_item_holds.active.order(:id).lock.each do |hold|
          hold.release!(reason: reason, expired: expired, at: at)
        end
        release_waitlist_offer!(order, at: at)
        order.promo_redemption&.update!(status: :released, released_at: at) if order.promo_redemption&.reserved?
        order.tickets.includes(:ticket_type, :pricing_tier, :order_item).where.not(status: :cancelled).each do |ticket|
          ticket.release_inventory! if ticket.order_item_id.nil?
          ticket.update!(status: :cancelled)
        end
        order.update!(
          status: expired ? :expired : :cancelled,
          cancelled_at: expired ? nil : at,
          expired_at: expired ? at : nil,
          expires_at: nil
        )
      end

      def issue_tickets!(order)
        order.order_items.item_ticket.each do |item|
          existing = order.tickets.where(order_item_id: item.id).order(:id).to_a
          (item.quantity - existing.length).times do
            existing << order.tickets.create!(
              order_item: item,
              ticket_type: item.ticket_type,
              pricing_tier: item.pricing_tier,
              event: order.event
            )
          end
          existing.each(&:issue_qr_code!)
        end
      end

      def finalize_waitlist_offer!(order)
        offer = order.waitlist_offer
        return unless offer&.claimed?

        offer.update!(status: :converted, converted_at: Time.current, token_version: offer.token_version + 1)
        offer.waitlist_entry.update!(status: :converted, expires_at: nil)
      end

      def release_waitlist_offer!(order, at: Time.current)
        offer = order.waitlist_offer
        return unless offer&.claimed?

        offer.update!(status: :expired, token_version: offer.token_version + 1)
        offer.waitlist_entry.update!(status: :waiting, expires_at: nil, notified_at: nil)
      end

      def record_promoter_commission!(order)
        attribution = order.referral_attribution
        return unless attribution

        amount = attribution.promoter.commission_for(order.order_items.sum(:organizer_proceeds_cents))
        return unless amount.positive?

        PromoterCommissionEntry.find_or_create_by!(idempotency_key: "commission:order:#{order.id}") do |entry|
          entry.promoter = attribution.promoter
          entry.order = order
          entry.kind = :earned
          entry.amount_cents = amount
          entry.currency = order.currency
          entry.occurred_at = Time.current
        end
      end

      def record_marketplace_purchase!(order)
        attribution = order.acquisition_attribution
        return unless attribution

        MarketplaceFunnelEvent.find_or_create_by!(order: order, stage: :purchase) do |funnel_event|
          funnel_event.event = order.event
          funnel_event.distribution_link = attribution.distribution_link
          funnel_event.event_referral = attribution.event_referral
          funnel_event.visitor_hash = attribution.visitor_hash
          funnel_event.source = attribution.source
          funnel_event.medium = attribution.medium
          funnel_event.campaign = attribution.campaign
          funnel_event.occurred_at = Time.current
        end
      end

      def finalize_promo!(order)
        redemption = order.promo_redemption
        return unless redemption&.reserved?

        redemption.promo_code.lock!
        redemption.promo_code.increment!(:current_uses)
        redemption.update!(status: :finalized, finalized_at: Time.current)
      end

      def cancel_provider_payments!(order, payments)
        payments.each do |payment|
          next if payment.provider_payment_id.blank?

          StripeService.cancel_payment_intent(
            payment.provider_payment_id,
            idempotency_key: "cancel:payment:#{payment.id}"
          )
        rescue Stripe::StripeError, StripeService::PaymentError => e
          ReconciliationException.create!(
            order: order,
            payment: payment,
            code: "provider_payment_cancel_failed",
            details: { error_class: e.class.name }
          )
          Sentry.capture_exception(e)
        end
      end
    end
  end
end
