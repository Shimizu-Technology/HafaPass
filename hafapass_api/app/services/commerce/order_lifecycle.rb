# frozen_string_literal: true

require "timeout"

module Commerce
  class OrderLifecycle
    class InvalidTransition < StandardError; end

    class << self
      # Match completion/failure's event -> order order before inspecting a
      # reservation. Recovery must never enter lifecycle code holding order first.
      def with_order_lock!(order)
        Order.transaction do
          lock_event_context!(order)
          order.lock!
          yield
        end
      end

      # late_completion: the caller confirmed with the provider that this
      # payment succeeded and the hold has only lapsed by time. Fulfil it
      # normally when the inventory is still free; otherwise release it and
      # refund the buyer automatically (LateCaptureRefundJob).
      def complete!(order, payment: nil, webhook_event: nil, provider_amount_cents: nil, provider_currency: nil, wallet_type: nil,
        late_completion: false)
        AuditContext.set(fail_open: true) do
          complete_with_audit!(order, payment: payment, webhook_event: webhook_event,
            provider_amount_cents: provider_amount_cents, provider_currency: provider_currency, wallet_type: wallet_type,
            late_completion: late_completion)
        end
      end

      def complete_with_audit!(order, payment: nil, webhook_event: nil, provider_amount_cents: nil, provider_currency: nil, wallet_type: nil,
        late_completion: false)
        completed_now = false
        completed_late = false

        Order.transaction do
          lock_event_context!(order)
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
            # Enqueued after commit (ApplicationJob.enqueue_after_transaction_commit).
            LateCaptureRefundJob.perform_later(payment.id) if payment
            next
          end

          holds = order.inventory_holds.order(:id).lock.to_a
          catalog_holds = order.catalog_item_holds.order(:id).lock.to_a
          # docs/LOCKING.md: order holds (3), offer (4), inventory (5).
          claimed_offer = lock_claimed_waitlist_offer!(order)
          # Checkout locks ticket types before the seat session. Match that
          # order so a reused hold cannot deadlock a payment finalization.
          holds.map(&:ticket_type).uniq(&:id).sort_by(&:id).each(&:lock!)
          holds.map(&:pricing_tier).compact.uniq(&:id).sort_by(&:id).each(&:lock!)
          seat_session = order.seat_hold_session
          seat_session&.lock!
          seat_hold_invalid = seat_session && (!seat_session.status_claimed? || seat_session.expires_at <= Time.current)
          unusable = holds.empty? || seat_hold_invalid || (holds + catalog_holds).any? { |hold| !hold.active? }
          lapsed = (holds + catalog_holds).any? { |hold| hold.expires_at <= Time.current }
          completed_late = lapsed && !unusable && late_completion && payment.present? &&
            late_capacity_available?(order, holds, catalog_holds, claimed_offer, seat_session)
          if unusable || (lapsed && !completed_late)
            release_locked_order!(order, reason: "payment_succeeded_after_hold_expiry", expired: true,
              claimed_offer: claimed_offer, holds: holds, catalog_holds: catalog_holds)
            mark_payment_succeeded!(payment)
            ReconciliationException.create!(
              order: order,
              payment: payment,
              webhook_event: webhook_event,
              code: "late_payment_success_after_hold_expiry"
            )
            LateCaptureRefundJob.perform_later(payment.id) if payment
            next
          end

          holds.each do |hold|
            hold.ticket_type.increment!(:quantity_sold, hold.quantity)
            if hold.pricing_tier
              hold.pricing_tier.increment!(:quantity_sold, hold.quantity)
            end
            hold.consume!
          end

          catalog_holds.each do |hold|
            hold.catalog_item.lock!
            hold.catalog_item.increment!(:quantity_sold, hold.quantity)
            hold.consume!
          end

          issued_tickets = issue_tickets!(order)
          Seating::SessionLifecycle.consume!(seat_session, tickets: issued_tickets) if seat_session
          finalize_promo!(order)
          finalize_waitlist_offer!(claimed_offer)
          record_promoter_commission!(order)
          mark_payment_succeeded!(payment)
          order.update!(status: :completed, completed_at: Time.current, expires_at: nil, wallet_type: wallet_type)
          AuditLogger.record!(action: "order.completed", auditable: order,
            organization: order.event.organization, event: order.event, outcome: "succeeded",
            deduplication_key: "order:#{order.id}:completed",
            after_data: { status: order.status }, metadata: { payment_id: payment&.id, late_completion: completed_late || nil }.compact,
            **(webhook_event ? { source: "provider" } : {}))
          record_marketplace_purchase!(order)
          EmailService.send_order_confirmation_async(order)
          completed_now = true
        end

        completed_now ? :completed : :unchanged
      end

      private :complete_with_audit!

      def fail!(order, payment: nil, failure_code: nil, failure_message: nil, reason: "payment_failed")
        Order.transaction do
          lock_event_context!(order)
          order.lock!
          payment&.lock!
          payment&.update!(
            status: :failed,
            failed_at: Time.current,
            failure_code: failure_code,
            failure_message: failure_message
          ) unless payment && (payment.succeeded? || payment.partially_refunded? || payment.refunded?)
          if order.pending?
            holds, catalog_holds = lock_order_holds!(order)
            release_locked_order!(order, reason: reason, claimed_offer: lock_claimed_waitlist_offer!(order),
              holds: holds, catalog_holds: catalog_holds)
          end
        end
      end

      def cancel!(order, reason: "buyer_cancelled")
        payments_to_cancel = []
        Order.transaction do
          lock_event_context!(order)
          order.lock!
          raise InvalidTransition, "Only pending orders can be cancelled" unless order.pending?

          holds, catalog_holds = lock_order_holds!(order)
          payments_to_cancel = order.payments.pending.where(provider: "stripe").order(:id).lock.to_a
          release_locked_order!(order, reason: reason, claimed_offer: lock_claimed_waitlist_offer!(order),
            holds: holds, catalog_holds: catalog_holds)
          order.payments.pending.update_all(status: Payment.statuses[:cancelled], updated_at: Time.current)
        end
        cancel_provider_payments!(order, payments_to_cancel)
      end

      def expire!(order, at: Time.current)
        # Ask the provider before releasing: a payment that already succeeded
        # (for example, its webhook is delayed) must be fulfilled or refunded,
        # never cancelled underneath the buyer.
        if (late = succeeded_provider_payment(order, at: at))
          payment, intent = late
          complete!(order, payment: payment, provider_amount_cents: intent.amount_received,
            provider_currency: intent.currency, late_completion: true)
          order.reload
          return order.expired? unless order.pending?
        end
        payments_to_cancel = []
        expired_now = false
        Order.transaction do
          lock_event_context!(order)
          order.lock!
          return false unless order.pending? && order.expires_at.present? && order.expires_at <= at

          holds, catalog_holds = lock_order_holds!(order)
          payments_to_cancel = order.payments.pending.where(provider: "stripe").order(:id).lock.to_a
          release_locked_order!(order, reason: "hold_expired", expired: true, at: at,
            claimed_offer: lock_claimed_waitlist_offer!(order), holds: holds, catalog_holds: catalog_holds)
          order.payments.pending.update_all(status: Payment.statuses[:cancelled], updated_at: at)
          expired_now = true
        end
        cancel_provider_payments!(order, payments_to_cancel)
        expired_now
      end

      private

      # Network call; never run while holding the order or event locks.
      def succeeded_provider_payment(order, at:)
        return unless order.pending? && order.expires_at.present? && order.expires_at <= at

        payment = order.payments.pending.where(provider: "stripe").where.not(provider_payment_id: nil).order(:id).last
        return unless payment && %w[test live].include?(payment.provider_environment)

        intent = Timeout.timeout(30.seconds) { StripeService.retrieve_payment_intent(payment) }
        return unless intent.status.to_s == "succeeded" && intent.id == payment.provider_payment_id &&
          intent.livemode == (payment.provider_environment == "live")

        [payment, intent]
      rescue Stripe::StripeError, StripeService::PaymentError, IOError, Timeout::Error => e
        Rails.logger.warn({ event: "order_expiry_payment_check_failed", order_id: order.id, error_class: e.class.name }.to_json)
        nil
      end

      # Runs under the completion locks (event, order, holds, ticket types,
      # tiers), which serialize every capacity decision for this event. Only
      # plain ticket orders qualify; seats, waitlist offers and add-ons are
      # released and refunded instead.
      def late_capacity_available?(order, holds, catalog_holds, claimed_offer, seat_session)
        return false if claimed_offer || seat_session || catalog_holds.any? || !order.event.published?

        now = Time.current
        types_free = holds.group_by(&:ticket_type).all? do |ticket_type, type_holds|
          ticket_type.available_quantity >= type_holds.sum(&:quantity)
        end
        tiers_free = holds.select(&:pricing_tier).group_by(&:pricing_tier).all? do |tier, tier_holds|
          next true unless tier.quantity_based?

          remaining = tier.quantity_limit - tier.quantity_sold - tier.inventory_holds.current.sum(:quantity) -
            tier.waitlist_offers.holding_inventory.sum(:quantity) - tier.active_seat_holds_quantity(now)
          remaining >= tier_holds.sum(&:quantity)
        end
        types_free && tiers_free && event_capacity_free?(order.event, holds.sum(&:quantity), now)
      end

      def event_capacity_free?(event, quantity, now)
        return true if event.max_capacity.blank?

        sold = event.ticket_types.sum(:quantity_sold)
        held = event.inventory_holds.current.sum(:quantity)
        offered = event.waitlist_offers.holding_inventory.sum(:quantity)
        seat_holds = SeatHold.status_active.joins(:seat_hold_session, :event_seat)
          .where(event_seats: { event_seating_configuration_id: event.event_seating_configuration&.id })
          .where(seat_hold_sessions: { status: SeatHoldSession.statuses[:active] })
          .where("seat_hold_sessions.expires_at > ?", now).count
        event.max_capacity - sold - held - offered - seat_holds >= quantity
      end

      def lock_event_context!(order)
        order.event.organization.lock! if order.waitlist_offer&.claimed?
        order.event.lock!
      end

      def lock_claimed_waitlist_offer!(order)
        offer = order.waitlist_offer
        return unless offer&.claimed?

        WaitlistLocks.with(entry: offer.waitlist_entry, offer: offer) { offer if offer.claimed? }
      end

      def lock_order_holds!(order)
        [order.inventory_holds.active.order(:id).lock.to_a, order.catalog_item_holds.active.order(:id).lock.to_a]
      end

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

        # Capture success predates any refund. A delayed or duplicate capture
        # notification must not erase the later financial outcome.
        unless payment.partially_refunded? || payment.refunded?
          payment.update!(status: :succeeded, succeeded_at: payment.succeeded_at || Time.current)
        end
        StripeProcessingFees.request!(payment)
      end

      def release_locked_order!(order, reason:, expired: false, at: Time.current, claimed_offer: nil,
        holds:, catalog_holds:)
        holds.select(&:active?).each do |hold|
          hold.release!(reason: reason, expired: expired, at: at)
        end
        catalog_holds.select(&:active?).each do |hold|
          hold.release!(reason: reason, expired: expired, at: at)
        end
        release_waitlist_offer!(claimed_offer, at: at)
        if order.seat_hold_session
          Seating::SessionLifecycle.release!(order.seat_hold_session, reason: reason, expired: expired, at: at,
            allow_claimed: true)
        end
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
        AuditLogger.record!(action: "order.#{expired ? 'expired' : 'cancelled'}", auditable: order,
          organization: order.event.organization, event: order.event, outcome: "succeeded",
          deduplication_key: "order:#{order.id}:#{order.status}",
          before_data: { status: "pending" }, after_data: { status: order.status },
          metadata: { reason: reason })
      end

      def issue_tickets!(order)
        issued = []
        order.order_items.item_ticket.each do |item|
          existing = order.tickets.where(order_item_id: item.id).order(:id).to_a
          assigned_holds = item.seat_holds.status_claimed.includes(:event_seat).order(:event_seat_id).to_a
          if assigned_holds.any?
            unless assigned_holds.length == item.quantity
              raise InvalidTransition, "Assigned seats do not match the order item quantity"
            end
            assigned_holds.each do |hold|
              ticket = existing.find { |candidate| candidate.event_seat_id == hold.event_seat_id }
              ticket ||= order.tickets.create!(
                order_item: item,
                ticket_type: item.ticket_type,
                pricing_tier: item.pricing_tier,
                event: order.event,
                event_seat: hold.event_seat
              )
              ticket.issue_qr_code!
              issued << ticket
            end
            next
          end
          (item.quantity - existing.length).times do
            existing << order.tickets.create!(
              order_item: item,
              ticket_type: item.ticket_type,
              pricing_tier: item.pricing_tier,
              event: order.event
            )
          end
          existing.each(&:issue_qr_code!)
          issued.concat(existing)
        end
        issued
      end

      def finalize_waitlist_offer!(offer)
        return unless offer&.claimed?

        offer.update!(status: :converted, converted_at: Time.current, token_version: offer.token_version + 1)
        offer.waitlist_entry.update!(status: :converted, expires_at: nil)
      end

      def release_waitlist_offer!(offer, at: Time.current)
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

          Timeout.timeout(30.seconds) do
            StripeService.cancel_payment_intent(
              payment.provider_payment_id,
              idempotency_key: "cancel:payment:#{payment.id}",
              payment: payment
            )
          end
        rescue Stripe::StripeError, StripeService::PaymentError, IOError, Timeout::Error => e
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
