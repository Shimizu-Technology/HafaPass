# frozen_string_literal: true

require "timeout"

module Commerce
  class OrderLifecycle
    class InvalidTransition < StandardError; end
    # Expiry asks Stripe whether a lapsed order's payment already succeeded.
    # Keep it short: the expiry job works through many orders per minute.
    PROVIDER_CHECK_TIMEOUT = 5.seconds

    class << self
      # Match completion/failure's event -> order order before inspecting a
      # reservation. Recovery must never enter lifecycle code holding order first.
      def with_order_lock!(order)
        Passes::Locking.with_lock_retry do
          Order.transaction do
            lock_event_context!(order)
            order.lock!
            yield
          end
        end
      end

      # late_completion: the caller confirmed with the provider that this
      # payment succeeded and the hold has only lapsed by time. Fulfil it
      # normally when the inventory is still free; otherwise release it and
      # refund the buyer automatically (LateCaptureRefundJob).
      #
      # The creator and hosted-checkout webhook already hold the event context
      # when passing event_context_locked. Every later lock is still acquired.
      #
      # provider_lookup: { provider_object_id:, livemode: } when the caller
      # retrieved the PaymentIntent over the authenticated API instead of
      # receiving a signed webhook. Together with the exact amount and
      # currency it is the evidence a never-fulfilled classification needs.
      def complete!(order, payment: nil, webhook_event: nil, provider_amount_cents: nil, provider_currency: nil, wallet_type: nil,
        late_completion: false, event_context_locked: false, provider_lookup: nil)
        if event_context_locked && !Order.connection.transaction_open?
          raise ArgumentError, "event_context_locked requires the caller's open transaction"
        end

        AuditContext.set(fail_open: true) do
          complete_with_audit!(order, payment: payment, webhook_event: webhook_event,
            provider_amount_cents: provider_amount_cents, provider_currency: provider_currency, wallet_type: wallet_type,
            late_completion: late_completion, event_context_locked: event_context_locked, provider_lookup: provider_lookup)
        end
      end

      def complete_with_audit!(order, payment: nil, webhook_event: nil, provider_amount_cents: nil, provider_currency: nil, wallet_type: nil,
        late_completion: false, event_context_locked: false, provider_lookup: nil)
        evidence = capture_evidence(webhook_event, provider_lookup, provider_amount_cents, provider_currency)
        completed_now = false
        completed_late = false

        Passes::Locking.with_lock_retry do
          completed_now = false
          completed_late = false
          Order.transaction do
          lock_event_context!(order) unless event_context_locked
          order.lock!
          payment&.lock!

          if payment && !provider_matches?(payment, provider_amount_cents, provider_currency)
            record_provider_mismatch!(order, payment, webhook_event, provider_amount_cents, provider_currency)
            next
          end

          if order.completed? || order.partially_refunded? || order.refunded?
            record_capture_on_released_or_fulfilled_order!(order, payment, webhook_event, evidence)
            next
          end

          # The legacy guard (no late-capture exception) stays until A3; a
          # classified payment never reopens either.
          reopen_expired = late_completion && webhook_event && order.online_door_card? && order.expired? &&
            payment && !late_capture_recorded?(payment)
          unless order.pending? || reopen_expired
            mark_payment_succeeded!(payment)
            # One late capture, one exception and one refund job: a second
            # notice for the same payment (the expiry job's own check, then
            # the webhook) must not open a duplicate.
            next if payment && late_capture_recorded?(payment)

            issue = ReconciliationException.create!(
              order: order,
              payment: payment,
              webhook_event: webhook_event,
              code: "late_payment_success_after_inventory_release",
              details: { order_status: order.status }
            )
            classify_order_capture!(order, payment, issue, webhook_event, evidence)
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
          inventory_valid = if reopen_expired
            catalog_holds.empty? && holds.all? { |hold| hold.expired? && hold.release_reason == "hold_expired" }
          else
            (holds + catalog_holds).all?(&:active?)
          end
          unusable = holds.empty? || seat_hold_invalid || !inventory_valid
          if !reopen_expired && !holds.empty? && pass_nights_exhausted?(holds)
            release_locked_order!(order, reason: "pass_all_included_nights_cancelled", expired: false,
              claimed_offer: claimed_offer, holds: holds, catalog_holds: catalog_holds)
            if payment.present?
              mark_payment_succeeded!(payment)
              issue = ReconciliationException.create!(
                order: order,
                payment: payment,
                webhook_event: webhook_event,
                code: "pass_all_included_nights_cancelled",
                details: { reason: "All included nights for a pass in this order were cancelled before completion" }
              )
              classify_order_capture!(order, payment, issue, webhook_event, evidence)
              LateCaptureRefundJob.perform_later(payment.id)
            end
            next
          end
          lapsed = reopen_expired || (holds + catalog_holds).any? { |hold| hold.expires_at <= Time.current }
          completed_late = lapsed && !unusable && late_completion && payment.present? &&
            late_capacity_available?(order, holds, catalog_holds, claimed_offer, seat_session)
          admission_ended = order.online_door_card? && door_admission_ended?(order.event, holds)
          if unusable || admission_ended || (lapsed && !completed_late)
            if order.pending?
              release_locked_order!(order, reason: "payment_succeeded_after_hold_expiry", expired: true,
                claimed_offer: claimed_offer, holds: holds, catalog_holds: catalog_holds)
            end
            mark_payment_succeeded!(payment)
            issue = ReconciliationException.create!(
              order: order,
              payment: payment,
              webhook_event: webhook_event,
              code: "late_payment_success_after_hold_expiry",
              details: admission_ended ? { reason: "admission_ended" } : {}
            )
            classify_order_capture!(order, payment, issue, webhook_event, evidence) if payment
            LateCaptureRefundJob.perform_later(payment.id) if payment
            next
          end

          holds.each do |hold|
            hold.ticket_type.increment!(:quantity_sold, hold.quantity)
            if hold.pricing_tier
              hold.pricing_tier.increment!(:quantity_sold, hold.quantity)
            end
            if reopen_expired
              hold.update!(status: :consumed, consumed_at: Time.current, released_at: nil, release_reason: nil)
            else
              hold.consume!
            end
          end

          catalog_holds.each do |hold|
            hold.catalog_item.lock!
            hold.catalog_item.increment!(:quantity_sold, hold.quantity)
            hold.consume!
          end

          issued_tickets = issue_tickets!(order)
          Seating::SessionLifecycle.consume!(seat_session, tickets: issued_tickets) if seat_session
          finalize_promo!(order, late: completed_late)
          finalize_waitlist_offer!(claimed_offer)
          record_promoter_commission!(order)
          mark_payment_succeeded!(payment)
          # The verified payment that fulfilled the order, recorded once so a
          # later distinct capture can be told apart without guessing.
          order.update!(status: :completed, completed_at: Time.current, expires_at: nil, expired_at: nil, wallet_type: wallet_type,
            fulfilled_by_payment_id: payment&.id)
          PublicEventCache.bump_after_commit! if completed_late
          AuditLogger.record!(action: "order.completed", auditable: order,
            organization: order.event.organization, event: order.event, outcome: "succeeded",
            deduplication_key: "order:#{order.id}:completed",
            after_data: { status: order.status }, metadata: { payment_id: payment&.id, late_completion: completed_late || nil }.compact,
            **(webhook_event ? { source: "provider" } : {}))
          record_marketplace_purchase!(order)
          EmailService.send_order_confirmation_async(order)
          completed_now = true
          end
        end

        completed_now ? :completed : :unchanged
      end

      private :complete_with_audit!

      def fail!(order, payment: nil, failure_code: nil, failure_message: nil, reason: "payment_failed")
        Passes::Locking.with_lock_retry do
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
      end

      def cancel!(order, reason: "buyer_cancelled", closed_checkout_session_id: nil)
        payments_to_cancel = []
        Passes::Locking.with_lock_retry do
          payments_to_cancel = []
          Order.transaction do
            lock_event_context!(order)
            order.lock!
            raise InvalidTransition, "Only pending orders can be cancelled" unless order.pending?

            holds, catalog_holds = lock_order_holds!(order)
            payments_to_cancel = order.payments.pending.where(provider: "stripe").order(:id).lock.to_a
            if reason == "box_office_cancelled" &&
                payments_to_cancel.any? { |payment| payment.stripe_checkout_session_id != closed_checkout_session_id }
              raise InvalidTransition, "The Stripe checkout changed. Reload to cancel it."
            end

            release_locked_order!(order, reason: reason, claimed_offer: lock_claimed_waitlist_offer!(order),
              holds: holds, catalog_holds: catalog_holds)
            order.payments.pending.update_all(status: Payment.statuses[:cancelled], stripe_checkout_url: nil, updated_at: Time.current)
          end
        end
        cancel_provider_payments!(order, payments_to_cancel)
      end

      def expire!(order, at: Time.current, provider_expired: false)
        # Ask the provider before releasing: a payment that already succeeded
        # (for example, its webhook is delayed) must be fulfilled or refunded,
        # never cancelled underneath the buyer.
        if !order.online_door_card? && (late = succeeded_provider_payment(order, at: at))
          payment, intent = late
          complete!(order, payment: payment, provider_amount_cents: intent.amount_received,
            provider_currency: intent.currency, late_completion: true,
            provider_lookup: { provider_object_id: intent.id, livemode: intent.livemode })
          order.reload
          return order.expired? unless order.pending?
        end
        payments_to_cancel = []
        expired_now = false
        Passes::Locking.with_lock_retry do
          payments_to_cancel = []
          expired_now = false
          Order.transaction do
            lock_event_context!(order)
            order.lock!
            return false unless order.pending? && order.expires_at.present? && (provider_expired || order.expires_at <= at)

            holds, catalog_holds = lock_order_holds!(order)
            payments_to_cancel = order.payments.pending.where(provider: "stripe").order(:id).lock.to_a
            release_locked_order!(order, reason: "hold_expired", expired: true, at: at,
              claimed_offer: lock_claimed_waitlist_offer!(order), holds: holds, catalog_holds: catalog_holds)
            order.payments.pending.update_all(status: Payment.statuses[:cancelled], stripe_checkout_url: nil, updated_at: at)
            expired_now = true
          end
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

        intent = Timeout.timeout(PROVIDER_CHECK_TIMEOUT) { StripeService.retrieve_payment_intent(payment) }
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
        return false if pass_nights_exhausted?(holds)

        now = Time.current
        types_free = holds.group_by(&:ticket_type).all? do |ticket_type, type_holds|
          available = order.online_door_card? ? ticket_type.door_available_quantity : ticket_type.available_quantity
          available >= type_holds.sum(&:quantity)
        end
        tiers_free = holds.select(&:pricing_tier).group_by(&:pricing_tier).all? do |tier, tier_holds|
          next true unless tier.quantity_based?

          remaining = tier.quantity_limit - tier.quantity_sold - tier.inventory_holds.current.sum(:quantity) -
            tier.waitlist_offers.holding_inventory.sum(:quantity) - tier.active_seat_holds_quantity(now)
          remaining >= tier_holds.sum(&:quantity)
        end
        types_free && tiers_free && event_capacity_free?(order.event, holds, now)
      end

      def pass_nights_exhausted?(holds)
        holds.map(&:ticket_type).uniq(&:id).any? do |ticket_type|
          ticket_type.pass? && !ticket_type.included_events.where.not(status: Event::INELIGIBLE_PASS_NIGHT_STATUSES).exists?
        end
      end

      def door_admission_ended?(event, holds, at: Time.current)
        return true if event.completed? || event.effective_ends_at <= at

        holds.map(&:ticket_type).uniq(&:id).any? do |type|
          if type.pass?
            !type.included_events.where.not(status: Event::INELIGIBLE_PASS_NIGHT_STATUSES + [:completed])
              .where("COALESCE(events.ends_at, events.starts_at) > ?", at).exists?
          else
            (event.ends_at || event.starts_at) <= at
          end
        end
      end

      def event_capacity_free?(event, holds, now)
        total_quantity = holds.sum(&:quantity)
        if event.max_capacity.present? && EventCapacity.remaining_for(event, at: now) < total_quantity
          return false
        end

        pass_demand = Hash.new(0)
        holds.each do |hold|
          next unless hold.ticket_type.pass?

          hold.ticket_type.included_events.where.not(status: Event::INELIGIBLE_PASS_NIGHT_STATUSES).each do |included_event|
            pass_demand[included_event] += hold.quantity
          end
        end
        pass_demand.all? do |included_event, demand|
          included_event.max_capacity.blank? || EventCapacity.remaining_for(included_event, at: now) >= demand
        end
      end

      def lock_event_context!(order)
        order.event.organization.lock! if order.waitlist_offer&.claimed?
        Passes::Locking.lock_events_for_order!(order)
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

      # What proved this capture, for NeverFulfilledClassification. A signed
      # webhook receipt names its own PaymentIntent; an API lookup passes the
      # retrieved intent's ID and mode. Anything else is no evidence.
      def capture_evidence(webhook_event, provider_lookup, amount_cents, currency)
        base = { "amount_cents" => amount_cents, "currency" => currency&.to_s&.downcase }
        if webhook_event
          object = webhook_event.payload.to_h.dig("data", "object").to_h
          base.merge("source" => "signed_webhook", "webhook_event_id" => webhook_event.id,
            "event_type" => webhook_event.event_type, "provider_object_id" => object["id"])
        elsif provider_lookup
          base.merge("source" => "provider_lookup", "provider_object_id" => provider_lookup[:provider_object_id],
            "livemode" => provider_lookup[:livemode])
        end
      end

      def late_capture_recorded?(payment)
        UnfulfilledCapture.exists?(payment_id: payment.id) ||
          ReconciliationException.where(payment: payment, code: LateCaptureRefund::CODES).exists?
      end

      # Order scope: the order was released and no capture on it fulfilled it.
      # Written in the same transaction as the capture and its exception.
      def classify_order_capture!(order, payment, issue, webhook_event, evidence)
        NeverFulfilledClassification.classify!(order: order, payment: payment, code: issue.code,
          provider_evidence: evidence, exception: issue, webhook_event: webhook_event)
      end

      # A success notice for an order that already completed, or that a
      # refund has since moved to partially refunded or refunded.
      #
      # - Never-fulfilled order: a distinct capture is another order-scope
      #   capture (the marker keeps its first time). It opens the ordinary
      #   late-capture exception but enqueues no refund: the order-wide refund
      #   path cannot return a second capture on its own balance, so its
      #   repayment waits for the per-payment workflow (tranche 4).
      # - Fulfilled order: a distinct capture is payment scope, keyed by the
      #   order's verified fulfilling payment. It never touches the sale.
      #   Legacy orders recover that payment only from the completion audit;
      #   without it the capture is quarantined as ambiguous ownership.
      def record_capture_on_released_or_fulfilled_order!(order, payment, webhook_event, evidence)
        return unless payment

        previously_captured = payment.succeeded? || payment.partially_refunded? || payment.refunded?
        mark_payment_succeeded!(payment)
        return unless NeverFulfilledClassification.applicable?(payment)
        return if UnfulfilledCapture.exists?(payment_id: payment.id)

        if order.never_fulfilled?
          return if late_capture_recorded?(payment)

          issue = ReconciliationException.create!(order: order, payment: payment, webhook_event: webhook_event,
            code: "late_payment_success_after_inventory_release",
            details: { order_status: order.status, second_capture: true })
          classify_order_capture!(order, payment, issue, webhook_event, evidence)
          return
        end
        return if payment.id == order.fulfilled_by_payment_id

        fulfilling_id = order.fulfilled_by_payment_id || recover_fulfilling_payment!(order, payment, previously_captured)
        return if fulfilling_id == :not_second_capture || fulfilling_id == payment.id

        if fulfilling_id.nil?
          ReconciliationException.find_by(payment: payment, code: NeverFulfilledClassification::OWNERSHIP_AMBIGUOUS_CODE) ||
            ReconciliationException.create!(order: order, payment: payment, webhook_event: webhook_event,
              code: NeverFulfilledClassification::OWNERSHIP_AMBIGUOUS_CODE,
              details: { reason: "no_completion_evidence", order_status: order.status })
          return
        end

        issue = ReconciliationException.find_by(payment: payment, code: NeverFulfilledClassification::SECOND_CAPTURE_CODE) ||
          ReconciliationException.create!(order: order, payment: payment, webhook_event: webhook_event,
            code: NeverFulfilledClassification::SECOND_CAPTURE_CODE,
            details: { fulfilling_payment_id: fulfilling_id, order_status: order.status })
        NeverFulfilledClassification.classify!(order: order, payment: payment, code: "unfulfilled_second_capture",
          capture_scope: "payment", provider_evidence: evidence, exception: issue, webhook_event: webhook_event)
      end

      # Positive completion provenance only: the order.completed audit's
      # payment_id naming a captured, unclassified payment on this order. The
      # audit is written fail-open, so its absence proves nothing and the
      # earliest capture is never assumed. Returns the fulfilling payment ID,
      # :not_second_capture for a repeated notice of the order's only capture,
      # or nil when ownership is ambiguous.
      def recover_fulfilling_payment!(order, payment, previously_captured)
        audit = AuditLog.where(action: "order.completed", deduplication_key: "order:#{order.id}:completed").order(:id).first
        claimed = audit&.metadata.to_h["payment_id"]
        candidate = order.payments.find_by(id: claimed) if claimed.present?
        if candidate && (candidate.succeeded? || candidate.partially_refunded? || candidate.refunded?) &&
            !UnfulfilledCapture.exists?(payment_id: candidate.id)
          order.update!(fulfilled_by_payment_id: candidate.id)
          AuditLogger.record!(action: "order.fulfilling_payment_recovered", auditable: order,
            organization: order.event.organization, event: order.event, outcome: "succeeded",
            deduplication_key: "order:#{order.id}:fulfilling_payment_recovered",
            metadata: { payment_id: candidate.id, completion_audit_id: audit.id })
          return candidate.id
        end

        others = order.payments.where(status: %i[succeeded partially_refunded refunded]).where.not(id: payment.id).exists?
        return :not_second_capture if candidate.nil? && previously_captured && !others

        nil
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
        if order.online_door_card?
          order.payments.where.not(stripe_checkout_session_id: nil).each do |payment|
            ExpireDoorCheckoutSessionJob.perform_later(payment.id)
          end
        end
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
          # Attendee details validated at checkout, in ticket order.
          attendees = Array(item.metadata.to_h["attendees"])
          assigned_holds = item.seat_holds.status_claimed.includes(:event_seat).order(:event_seat_id).to_a
          if assigned_holds.any?
            if item.ticket_type.pass?
              raise InvalidTransition, "Multi-night pass ticket types cannot be issued with assigned seats"
            end
            unless assigned_holds.length == item.quantity
              raise InvalidTransition, "Assigned seats do not match the order item quantity"
            end
            assigned_holds.each_with_index do |hold, index|
              ticket = existing.find { |candidate| candidate.event_seat_id == hold.event_seat_id }
              ticket ||= order.tickets.create!(
                order_item: item,
                ticket_type: item.ticket_type,
                pricing_tier: item.pricing_tier,
                event: order.event,
                event_seat: hold.event_seat,
                **attendee_attributes(order, attendees[index])
              )
              ticket.issue_qr_code!
              record_ticket_responses!(order, item, ticket, attendees[index])
              issued << ticket
            end
            next
          end
          (item.quantity - existing.length).times do
            # Assigned at insert, so issue_qr_code! below needs no second write.
            existing << order.tickets.create!(
              order_item: item,
              ticket_type: item.ticket_type,
              pricing_tier: item.pricing_tier,
              event: order.event,
              qr_code: SecureRandom.uuid,
              **attendee_attributes(order, attendees[existing.length])
            )
          end
          existing.each_with_index do |ticket, index|
            ticket.issue_qr_code!
            record_ticket_responses!(order, item, ticket, attendees[index])
            # Night tickets copy the pass holder's attendee name and email.
            Passes::Issuance.call(order: order, parent_ticket: ticket) if ticket.pass_parent?
          end
          issued.concat(existing)
        end
        issued
      end

      # The buyer stays the ticket holder; only the name (and email, when
      # collected) printed on the ticket and shown at the door change.
      def attendee_attributes(order, attendee)
        name = attendee.to_h["attendee_name"].presence
        return {} unless name

        { attendee_name: name, attendee_email: attendee["attendee_email"].presence || order.buyer_email,
          holder_email: order.buyer_email }
      end

      # Idempotent: a retried issuance never duplicates a ticket's answers.
      # Questions are key-share locked so they cannot be deleted mid-issuance;
      # RegistrationQuestion refuses deletion while a pending order holds
      # answers. If one is missing anyway (removed outside the app), tickets
      # still issue, the accepted snapshot stays on the order item, and the
      # gap is reported for follow-up.
      def record_ticket_responses!(order, item, ticket, attendee)
        answers = Array(attendee.to_h["answers"])
        return if answers.empty?

        answered = ticket.registration_responses.pluck(:registration_question_id).to_set
        questions = order.event.registration_questions.where(id: answers.map { |answer| answer["question_id"] })
          .order(:id).lock("FOR KEY SHARE").index_by(&:id)
        answers.each do |answer|
          question = questions[answer["question_id"]]
          if question.nil?
            report_missing_question!(order, item, answer)
            next
          end
          next if answered.include?(question.id)

          ticket.registration_responses.create!(
            order: order,
            registration_question: question,
            prompt_snapshot: answer["prompt"],
            kind_snapshot: RegistrationQuestion.kinds.fetch(answer["kind"]),
            required_snapshot: answer["required"] == true,
            options_snapshot: Array(answer["options"]),
            answer: { "value" => answer["value"] },
            answered_at: item.created_at
          )
        end
      end

      def report_missing_question!(order, item, answer)
        message = "Registration question #{answer['question_id']} was deleted before order #{order.id} was paid; " \
          "its answer remains on order item #{item.id}"
        Rails.logger.warn("[OrderLifecycle] #{message}")
        Sentry.capture_message(message, level: :warning)
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

      # A late completion's hold lapsed, so another buyer may have taken the
      # code's last use meanwhile. The buyer already paid the discounted price:
      # complete anyway (one use over max_uses) and leave an audit note rather
      # than refund a paid order over a promo count.
      def finalize_promo!(order, late: false)
        redemption = order.promo_redemption
        return unless redemption&.reserved?

        promo = redemption.promo_code
        promo.lock!
        if late && promo.max_uses
          others = promo.promo_redemptions.where.not(id: redemption.id)
          used = others.finalized.count + others.reserved.joins(:order)
            .where(orders: { status: Order.statuses[:pending] }).where("orders.expires_at > ?", Time.current).count
          if used >= promo.max_uses
            AuditLogger.record!(action: "promo_code.over_redeemed", auditable: promo,
              organization: order.event.organization, event: order.event, outcome: "succeeded",
              deduplication_key: "promo_code:#{promo.id}:over_redeemed:order:#{order.id}",
              metadata: { order_id: order.id, max_uses: promo.max_uses, uses_before: used,
                note: "Payment finished after the hold expired; the buyer paid the discounted price, so the order was completed" })
          end
        end
        promo.increment!(:current_uses)
        redemption.update!(status: :finalized, finalized_at: Time.current)
      end

      def cancel_provider_payments!(order, payments)
        payments.each do |payment|
          next if payment.provider_payment_id.blank? || order.online_door_card?

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
