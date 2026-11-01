# frozen_string_literal: true

require "timeout"

module Commerce
  class OrderCreator
    HOLD_DURATION = 10.minutes
    SETUP_LEASE_DURATION = 1.minute
    PROVIDER_REQUEST_TIMEOUT = 30.seconds

    PAID_SALES_OPEN_SOON = "Paid ticket sales open soon"
    PROMO_CODE_REQUIRED = "Re-enter your promo code and try again"
    # Stripe's smallest USD card charge. A promo that leaves 1–49¢ cannot be paid.
    MINIMUM_CHARGE_CENTS = 50
    MINIMUM_CHARGE_MESSAGE = "Card payments must be at least $0.50. Remove the promo code or add tickets."
    ACTIVE_CHECKOUT_EXISTS = "You already have a checkout in progress for this event. Finish or cancel it, " \
      "or try again in 10 minutes."
    NETWORK_HOLD_LIMIT = "Too many tickets are being held from your network right now. Try again in a few minutes."
    NETWORK_FREE_LIMIT = "Your network has reached the free ticket limit for this event. " \
      "Contact the organizer if you need more tickets."
    # Guam carrier NAT and venue Wi-Fi put many buyers behind one address, so
    # the per-network caps start loose (held) or off (free) and log every
    # denial for tuning. See docs/OPERATIONS_RUNBOOK.md.
    DEFAULT_MAX_HELD_TICKETS_PER_IP = 60
    DEFAULT_MAX_FREE_TICKETS_PER_IP = 0
    FREE_TICKET_WINDOW = 1.hour
    CAP_ALERT_INTERVAL = 10.minutes
    @cap_alerts = {}
    @cap_alert_mutex = Mutex.new
    class CheckoutError < StandardError; end
    class PriceChanged < CheckoutError; end
    class RefreshRequired < PriceChanged; end
    LEGACY_REFRESH_WINDOW_DAYS = Integer(ENV.fetch("FEE_CHANGE_LEGACY_REFRESH_DAYS", "7"))

    Result = Data.define(:order, :payment, :payment_intent, :guest_access_token)

    def self.call(**)
      new(**).call
    end

    def self.cap_alert_due?(key, now: Time.current)
      @cap_alert_mutex.synchronize do
        last = @cap_alerts[key]
        next false if last && last > now - CAP_ALERT_INTERVAL

        @cap_alerts.delete_if { |_entry, at| at <= now - CAP_ALERT_INTERVAL } if @cap_alerts.size > 500
        @cap_alerts[key] = now
        true
      end
    end

    def self.reset_cap_alerts!
      @cap_alert_mutex.synchronize { @cap_alerts.clear }
    end

    def initialize(event:, line_items:, buyer_email:, buyer_name:, buyer_phone: nil, marketing_opt_in: false, user: nil, promo_code_id: nil, promo_code: nil,
      payment_required: nil, service_fee: true, complimentary: false, source: nil, payment_method: nil,
      payment_provider: nil, buyer_terms_version: nil, buyer_terms_digest: nil, buyer_terms_accepted_at: nil,
      catalog_items: nil, registration_answers: nil, waiver_acceptances: nil, referral_code: nil,
      attribution: nil, waitlist_offer_token: nil, seat_hold_token: nil, live_money_proof_authorization: nil,
      cash_sale_key: nil, cash_sale_request_digest: nil, checkout_key_digest: nil, checkout_request_digest: nil,
      checkout_attempt: nil, checkout_lease_token: nil, expected_total_cents: nil, client_quote_required: false,
      checkout_ip_digest: nil, enforce_buyer_limits: false, locale: AppLocale::DEFAULT)
      @event = event
      @line_items = line_items
      @buyer_email = buyer_email
      @buyer_name = buyer_name
      @buyer_phone = buyer_phone
      @marketing_opt_in = marketing_opt_in
      @user = user
      @promo_code_id = promo_code_id
      # The code the buyer typed is the only selector. A promo ID never picks a
      # code on its own, so guessing another code's ID cannot apply its discount.
      @promo_code_input = promo_code
      @payment_required = payment_required
      @service_fee = service_fee
      @complimentary = complimentary
      @source = source
      @payment_method = payment_method
      @payment_provider = payment_provider
      @buyer_terms_version = buyer_terms_version
      @buyer_terms_digest = buyer_terms_digest
      @buyer_terms_accepted_at = buyer_terms_accepted_at
      @catalog_items = catalog_items || []
      @registration_answers = registration_answers || {}
      @waiver_acceptances = waiver_acceptances || []
      @referral_code = referral_code
      @attribution = attribution || {}
      @waitlist_offer_token = waitlist_offer_token
      @seat_hold_token = seat_hold_token
      @live_money_proof_authorization = live_money_proof_authorization
      @checkout_key_digest = checkout_key_digest
      @checkout_request_digest = checkout_request_digest
      @checkout_attempt = checkout_attempt
      @checkout_lease_token = checkout_lease_token
      @expected_total_cents = expected_total_cents
      @client_quote_required = client_quote_required
      # Public buyer checkout only (one live checkout per buyer, per-network
      # caps, blank max_per_order = 10): staff, guest-list and cash sales are trusted.
      @checkout_ip_digest = checkout_ip_digest
      @enforce_buyer_limits = enforce_buyer_limits
      @cash_sale_key = cash_sale_key
      @cash_sale_request_digest = cash_sale_request_digest
      # The buyer's language for receipts and ticket emails; staff-created orders stay English.
      @locale = AppLocale.normalize(locale) || AppLocale::DEFAULT
    end

    def call
      if @checkout_key_digest && !@checkout_attempt
        claim = CheckoutAttempt.claim!(key_digest: @checkout_key_digest, request_digest: @checkout_request_digest)
        @checkout_attempt = claim.attempt
        @checkout_lease_token = claim.lease_token
      end
      order = nil
      payment = nil

      Order.transaction do
        if @checkout_attempt
          @checkout_attempt.lock!
          unless @checkout_attempt.checkout_key_digest == @checkout_key_digest && @checkout_attempt.request_digest == @checkout_request_digest
            raise CheckoutAttempt::Conflict, "Checkout recovery does not match this request"
          end
          @checkout_attempt.verify_owner!(@checkout_lease_token) unless @checkout_attempt.order_id
        end
        # Only offer claims need the organization rank before the event.
        event.organization.lock! if waitlist_offer_token.present?
        # Serialize capacity decisions while permitting FK key-share checks in
        # an independent seat-release transaction waiting on this checkout.
        event.lock!("FOR NO KEY UPDATE")
        if @checkout_key_digest && (previous = @checkout_attempt&.order || Order.find_by(checkout_key_digest: @checkout_key_digest))
          unless previous.checkout_key_digest == @checkout_key_digest && previous.event_id == event.id && previous.checkout_request_digest == @checkout_request_digest &&
              previous.checkout_recovery_expires_at&.future?
            raise CheckoutError, "Checkout recovery does not match this request or has expired"
          end
          order = previous
          payment = previous.payments.order(:id).last
          @checkout_attempt&.reserve!(previous)
          next
        end
        validate_launch_scope!
        raise CheckoutError, "This event is not currently on sale" unless event.sales_open?
        offer = claimable_waitlist_offer!
        offer&.update!(status: :claimed, claimed_at: Time.current)
        selections = locked_selections!(offer: offer)
        LivePilot.enforce_inventory_cap!(
          event: event, requested_quantity: selections.sum { |selection| selection[:quantity] }
        )
        validate_seating_selection!(selections)
        catalog_selections = locked_catalog_selections!
        enforce_event_capacity!(selections.sum { |selection| selection[:quantity] }, offer: offer)
        validate_registration!
        promoter = locked_promoter
        totals = calculate_totals(selections, catalog_selections)
        # Only buyer checkout can come from a stale cached page; server-side
        # callers such as guest list redemption never send a displayed total.
        if @client_quote_required && @expected_total_cents.blank? && FeeChange.where.not(activated_at: nil)
            .where("activated_at >= ?", LEGACY_REFRESH_WINDOW_DAYS.days.ago).exists?
          raise RefreshRequired, "Prices were updated — please refresh the page to see the current total."
        end
        if @expected_total_cents.present? && @expected_total_cents.to_s != totals[:total_cents].to_s
          raise PriceChanged, "Ticket price changed. Review the updated total before paying."
        end
        # Free orders never contact a payment provider and must remain usable
        # even when paid checkout is unavailable.
        requires_payment = totals[:total_cents].positive? &&
          (payment_required.nil? ? StripeService.payment_enabled? : payment_required)
        validate_production_payment!(totals, requires_payment)
        # Stripe's minimum only; cash and card-present terminals have none.
        if requires_payment && stripe_payment? && totals[:total_cents] < MINIMUM_CHARGE_CENTS
          raise CheckoutError, MINIMUM_CHARGE_MESSAGE
        end
        validate_live_money_proof_scope!(totals)
        enforce_buyer_checkout_limits!(selections, totals) if @enforce_buyer_limits
        expires_at = requires_payment && totals[:total_cents].positive? ? HOLD_DURATION.from_now : 1.minute.from_now

        order = Order.create!(
          user: user,
          event: event,
          promo_code: totals[:promo_code],
          status: :pending,
          currency: "usd",
          subtotal_cents: totals[:subtotal_cents],
          service_fee_cents: totals[:service_fee_cents],
          discount_cents: totals[:discount_cents],
          total_cents: totals[:total_cents],
          buyer_email: buyer_email,
          buyer_name: buyer_name,
          buyer_phone: buyer_phone,
          marketing_opt_in: @marketing_opt_in,
          locale: @locale,
          source: source,
          payment_method: payment_method,
          checkout_key_digest: @checkout_key_digest,
          checkout_request_digest: @checkout_request_digest,
          checkout_recovery_expires_at: @checkout_key_digest ? 30.minutes.from_now : nil,
          checkout_ip_digest: @checkout_ip_digest,
          cash_sale_key: @cash_sale_key,
          cash_sale_request_digest: @cash_sale_request_digest,
          buyer_terms_version: buyer_terms_version,
          buyer_terms_digest: buyer_terms_digest,
          buyer_terms_accepted_at: buyer_terms_accepted_at,
          fee_policy_snapshot: event.fee_policy,
          buyer_fee_percent_snapshot: event.buyer_fee_percent,
          processing_fee_bearer_snapshot: totals[:processing_fee_bearer],
          organizer_fee_cents: totals[:organizer_fee_cents],
          expires_at: expires_at
        )

        if event.live_money_proof_candidate?
          LiveMoneyProofAuthorizations::Manager.claim!(
            authorization: live_money_proof_authorization, order: order, amount_cents: totals[:total_cents],
            user: user, buyer_email: buyer_email
          )
        end

        create_ledger!(order, selections, catalog_selections, totals, expires_at)
        claim_seat_hold!(order)
        reserve_promo!(order, totals[:promo_code], totals[:discount_cents], expires_at)
        record_registration!(order)
        record_referral!(order, promoter)
        record_acquisition!(order)
        offer&.update!(order: order)

        if requires_payment && order.total_cents.positive?
          provider = payment_provider.presence || "stripe"
          # Read once so the environment and its platform account always agree.
          payment_mode = SiteSetting.instance.payment_mode if provider == "stripe"
          payment = order.payments.create!(
            provider: provider,
            provider_environment: payment_mode,
            provider_platform_account_id: payment_mode ? StripeService.platform_account_id(payment_mode) : nil,
            idempotency_key: "#{provider}:payment:order:#{order.id}",
            amount_cents: order.total_cents,
            currency: order.currency,
            status: :pending
          )
        elsif order.total_cents.positive? && payment_method.present?
          payment = order.payments.create!(
            provider: payment_method,
            provider_payment_id: "#{payment_method}_order_#{order.id}",
            idempotency_key: "#{payment_method}:order:#{order.id}",
            amount_cents: order.total_cents,
            currency: order.currency,
            provider_payload: { simulated: !Rails.env.production? },
            status: :pending
          )
          OrderLifecycle.complete!(
            order,
            payment: payment,
            provider_amount_cents: payment.amount_cents,
            provider_currency: payment.currency
          )
        elsif order.total_cents.positive? && !Rails.env.production? && SiteSetting.instance.simulate_mode?
          payment = order.payments.create!(
            provider: "stripe",
            provider_environment: "simulate",
            provider_payment_id: "sim_pi_#{SecureRandom.hex(12)}",
            provider_payload: { simulated: true },
            idempotency_key: "simulation:payment:order:#{order.id}",
            amount_cents: order.total_cents,
            currency: order.currency,
            status: :pending
          )
          OrderLifecycle.complete!(order, payment: payment, provider_amount_cents: payment.amount_cents,
            provider_currency: payment.currency)
        else
          OrderLifecycle.complete!(order)
        end
        @checkout_attempt&.reserve!(order)
      end

      intent = if payment&.provider == "stripe" && payment.provider_payment_id.present? && order.pending?
        PaymentRecovery.call(order: order).payment_intent
      else
        create_provider_payment!(order, payment)
      end
      order.reload
      guest_access_token = GuestOrderAccess.issue!(order) if order.user_id.nil?
      Result.new(order: order, payment: payment&.reload, payment_intent: intent, guest_access_token: guest_access_token)
    rescue StripeService::PaymentError => e
      raise CheckoutError, e.message
    rescue ActiveRecord::RecordInvalid => e
      raise CheckoutError, e.record.errors.full_messages.to_sentence
    end

    private

    attr_reader :event, :line_items, :buyer_email, :buyer_name, :buyer_phone, :user, :promo_code_id,
      :payment_required, :service_fee, :complimentary, :source, :payment_method, :payment_provider
    attr_reader :buyer_terms_version, :buyer_terms_digest, :buyer_terms_accepted_at
    attr_reader :catalog_items, :registration_answers, :waiver_acceptances, :referral_code, :attribution,
      :waitlist_offer_token, :seat_hold_token, :live_money_proof_authorization

    def validate_launch_scope!
      unless LaunchCapabilities.enabled?(:assigned_seating)
        selected_ids = normalized_quantities.keys
        seated = event.event_seating_configuration&.event_seats&.where(ticket_type_id: selected_ids)&.exists?
        if seat_hold_token.present? || seated
          raise CheckoutError, "Assigned seating is not available in this release"
        end
      end
      unless LaunchCapabilities.enabled?(:advanced_sales_tools)
        required_definitions = event.registration_questions.published.where(required: true).exists? ||
          event.event_waivers.published.where(required: true).exists?
        if catalog_items.present? || registration_answers.present? || waiver_acceptances.present? || required_definitions
          raise CheckoutError, "Event extras and custom registration are not available in this release"
        end
      end
    end

    def stripe_payment?
      payment_provider.blank? || payment_provider == "stripe"
    end

    # A blank limit means 10 for public checkout. Staff sales (box office,
    # guest list, cash) keep a blank limit as unlimited.
    def max_per_order_for(ticket_type)
      ticket_type.max_per_order || (@enforce_buyer_limits ? TicketType::DEFAULT_MAX_PER_ORDER : nil)
    end

    def validate_production_payment!(totals, requires_payment)
      return unless Rails.env.production? && totals[:total_cents].positive?
      return if !requires_payment && source == "box_office" && payment_method == "door_cash"

      unless requires_payment
        raise CheckoutError, "A recorded payment is required for paid tickets"
      end
      stripe = stripe_payment?
      if stripe && SiteSetting.instance.simulate_mode?
        raise CheckoutError, "Paid tickets are not on sale yet: HåfaPass has not turned on payments"
      end
      # Production test mode is a QA tool: only platform admins buy paid
      # tickets with test cards, so no one else holds a test-paid ticket that
      # a door would admit. Free tickets stay open to everyone.
      raise CheckoutError, PAID_SALES_OPEN_SOON if stripe && SiteSetting.instance.test_mode? && !user&.admin?
      unless event.organization.payout_ready?
        raise CheckoutError, "Paid tickets are not on sale until the organizer adds payout details"
      end
    end

    def validate_live_money_proof_scope!(totals)
      unless event.live_money_proof_candidate?
        raise CheckoutError, "A live-money proof authorization cannot be used for a normal event" if
          live_money_proof_authorization
        return
      end
      unless live_money_proof_authorization&.event_id == event.id
        raise CheckoutError, "An approved live-money proof authorization is required"
      end
      unless user&.admin? && promo_code_id.blank? && @promo_code_input.blank? && catalog_items.empty? && referral_code.blank? &&
          waitlist_offer_token.blank? && seat_hold_token.blank? && totals[:total_cents].between?(1, live_money_proof_authorization.max_amount_cents)
        raise CheckoutError, "The live-money proof order exceeds its approved buyer, item, or amount scope"
      end
    end

    def validate_seating_selection!(selections)
      configuration = event.event_seating_configuration
      return unless configuration&.status_active?

      seated_ticket_type_ids = configuration.event_seats.distinct.pluck(:ticket_type_id)
      selects_reserved_inventory = selections.any? { |selection| seated_ticket_type_ids.include?(selection[:ticket_type].id) }
      if selects_reserved_inventory && seat_hold_token.blank?
        raise CheckoutError, "Select and reserve seats before checkout"
      end
      if seat_hold_token.present? && !selects_reserved_inventory
        raise CheckoutError, "The seat hold does not match this ticket order"
      end
    end

    def claim_seat_hold!(order)
      return if seat_hold_token.blank?

      Seating::SessionLifecycle.claim!(
        token: seat_hold_token,
        event: event,
        order: order,
        order_items: order.order_items.item_ticket.to_a
      )
    rescue Seating::SessionLifecycle::SessionError => e
      raise CheckoutError, e.message
    end

    def normalized_quantities
      raise CheckoutError, "line_items is required and must be a non-empty array" unless line_items.is_a?(Array) && line_items.any?

      line_items.each_with_object(Hash.new(0)) do |item, quantities|
        ticket_type_id = item[:ticket_type_id] || item["ticket_type_id"]
        quantity = (item[:quantity] || item["quantity"]).to_i
        raise CheckoutError, "Quantity must be greater than 0" unless quantity.positive?

        quantities[ticket_type_id.to_i] += quantity
      end
    end

    def locked_selections!(offer: nil)
      if offer && seat_hold_token.present?
        raise CheckoutError, "Waitlist offers cannot be combined with an assigned-seat hold"
      end
      enforce_offer_selection!(offer) if offer
      quantities = normalized_quantities.sort
      # docs/LOCKING.md: acquire every ticket type before any tier or seat
      # session, including checkouts with several ticket types.
      ticket_types = quantities.to_h do |ticket_type_id, _quantity|
        ticket_type = event.ticket_types.lock.find_by(id: ticket_type_id)
        raise CheckoutError, "Ticket type #{ticket_type_id} not found for this event" unless ticket_type

        [ticket_type_id, ticket_type]
      end
      provisional_session = Seating::Credential.find_session(seat_hold_token) if seat_hold_token.present?
      provisional_holds = provisional_session&.seat_holds&.status_active&.includes(:pricing_tier)&.to_a || []
      tiers = quantities.to_h do |ticket_type_id, _quantity|
        ticket_type = ticket_types.fetch(ticket_type_id)
        seat_hold = provisional_holds.find { |hold| hold.event_seat.ticket_type_id == ticket_type_id }
        tier = if complimentary
          nil
        elsif seat_hold
          seat_hold.pricing_tier
        else
          ticket_type.active_pricing_tier
        end
        [ticket_type_id, tier]
      end
      tiers.values.compact.uniq(&:id).sort_by(&:id).each(&:lock!)
      seat_hold_session_for_checkout if seat_hold_token.present?

      quantities.map do |ticket_type_id, quantity|
        ticket_type = ticket_types.fetch(ticket_type_id)
        raise CheckoutError, "#{ticket_type.name} is not currently on sale" unless ticket_type.on_sale?
        seat_holds = seat_hold_selection(ticket_type.id)
        if seat_holds.map(&:id).sort != provisional_holds.select { |hold| hold.event_seat.ticket_type_id == ticket_type_id }.map(&:id).sort ||
            (!complimentary && seat_holds.any? && seat_holds.first.pricing_tier_id != tiers[ticket_type_id]&.id)
          raise CheckoutError, "Your seat hold changed; retry checkout"
        end
        reserved_seat_quantity = seat_holds.length
        available = ticket_type.available_quantity + reserved_seat_quantity +
          (offer&.ticket_type_id == ticket_type.id ? offer.quantity : 0)
        if quantity > available
          raise CheckoutError, "Only #{available} tickets available for #{ticket_type.name}"
        end
        max_per_order = max_per_order_for(ticket_type)
        if max_per_order && quantity > max_per_order
          raise CheckoutError, "Maximum #{max_per_order} tickets per order for #{ticket_type.name}"
        end
        enforce_door_allocation!(ticket_type, quantity, reserved_seat_quantity: reserved_seat_quantity) if source == "box_office"
        enforce_buyer_limit!(ticket_type, quantity)

        tier = tiers[ticket_type_id]
        if tier&.quantity_based?
          enforce_pricing_tier_capacity!(tier, quantity, offer: offer, reserved_seat_quantity: reserved_seat_quantity)
        end
        selection = {
          ticket_type: ticket_type,
          pricing_tier: tier,
          unit_price_cents: complimentary ? 0 : (seat_holds.first&.unit_price_cents || tier&.price_cents || ticket_type.price_cents),
          quantity: quantity
        }
        if offer
          selection[:pricing_tier] = offer.pricing_tier
          selection[:unit_price_cents] = offer.unit_price_cents
        end
        selection
      end
    end

    def seat_hold_selection(ticket_type_id)
      return [] if seat_hold_token.blank?

      session = seat_hold_session_for_checkout
      holds = session.seat_holds.status_active.joins(:event_seat)
        .where(event_seats: { ticket_type_id: ticket_type_id }).includes(:pricing_tier).order(:event_seat_id).lock.to_a
      if holds.map { |hold| [hold.pricing_tier_id, hold.unit_price_cents] }.uniq.length > 1
        raise CheckoutError, "Selected seats in one price category must share the same active price"
      end
      holds
    end

    def seat_hold_session_for_checkout
      return @seat_hold_session_for_checkout if defined?(@seat_hold_session_for_checkout)

      session = Seating::Credential.find_session(seat_hold_token)
      session&.lock!
      unless session&.status_active? && session.expires_at > Time.current &&
          session.event_seating_configuration.event_id == event.id
        raise CheckoutError, "Your seat hold is invalid or expired"
      end
      @seat_hold_session_for_checkout = session
    end

    def enforce_offer_selection!(offer)
      quantities = normalized_quantities
      unless quantities == { offer.ticket_type_id => offer.quantity }
        raise CheckoutError, "This waitlist offer must be claimed for exactly #{offer.quantity} #{offer.ticket_type.name} tickets"
      end
    end

    def claimable_waitlist_offer!
      return if waitlist_offer_token.blank?

      offer = WaitlistCredential.find_offer(waitlist_offer_token)
      raise CheckoutError, "This waitlist offer is invalid or expired" unless offer

      WaitlistLocks.with(entry: offer.waitlist_entry, offer: offer) do
        unless offer.active? && offer.event_id == event.id &&
            offer.waitlist_entry.email.casecmp?(buyer_email.to_s.strip)
          raise CheckoutError, "This waitlist offer is invalid or expired"
        end
      end

      offer
    end

    def normalized_catalog_quantities
      raise CheckoutError, "catalog_items must be an array" unless catalog_items.is_a?(Array)

      catalog_items.each_with_object({}) do |item, selections|
        catalog_item_id = item[:catalog_item_id] || item["catalog_item_id"]
        quantity = (item[:quantity] || item["quantity"]).to_i
        amount_cents = item[:amount_cents] || item["amount_cents"]
        raise CheckoutError, "Catalog item and quantity are required" if catalog_item_id.blank? || !quantity.positive?
        raise CheckoutError, "A catalog item can only appear once" if selections.key?(catalog_item_id.to_i)

        selections[catalog_item_id.to_i] = { quantity: quantity, amount_cents: amount_cents }
      end
    end

    def locked_catalog_selections!
      normalized_catalog_quantities.sort.map do |catalog_item_id, requested|
        item = event.catalog_items.lock.find_by(id: catalog_item_id)
        raise CheckoutError, "Catalog item #{catalog_item_id} is not available" unless item&.active?
        if requested[:quantity] > item.available_quantity
          raise CheckoutError, "Only #{item.available_quantity} remain for #{item.name}"
        end

        unit_price = item.price_for(requested[:amount_cents])
        { catalog_item: item, quantity: requested[:quantity], unit_price_cents: unit_price }
      rescue ArgumentError => e
        raise CheckoutError, e.message
      end
    end

    def enforce_door_allocation!(ticket_type, requested_quantity, reserved_seat_quantity: 0)
      remaining = ticket_type.door_available_quantity(reserved_seat_quantity: reserved_seat_quantity)
      return if requested_quantity <= remaining

      raise CheckoutError, "Only #{remaining} door tickets remain for #{ticket_type.name}"
    end

    def enforce_buyer_limit!(ticket_type, requested_quantity)
      return if ticket_type.max_per_buyer.blank?

      normalized_email = buyer_email.to_s.strip.downcase
      completed_quantity = Ticket.joins(:order)
        .where(ticket_type: ticket_type, status: [:issued, :checked_in])
        .where("LOWER(orders.buyer_email) = ?", normalized_email)
        .count
      held_quantity = InventoryHold.joins(:order).current
        .where(ticket_type: ticket_type)
        .where("LOWER(orders.buyer_email) = ?", normalized_email)
        .sum(:quantity)
      remaining = [ticket_type.max_per_buyer - completed_quantity - held_quantity, 0].max
      return if requested_quantity <= remaining

      raise CheckoutError, "Purchase limit is #{ticket_type.max_per_buyer} tickets per buyer for #{ticket_type.name}"
    end

    # Runs under the event lock taken above, so concurrent checkouts for one
    # event cannot both pass. Same-key recovery returns before reaching here.
    def enforce_buyer_checkout_limits!(selections, totals)
      live = event.orders.pending.where("orders.expires_at > ?", Time.current)
      same_buyer = live.where("LOWER(BTRIM(orders.buyer_email)) = ?", buyer_email.to_s.strip.downcase)
      same_buyer = same_buyer.or(live.where(user_id: user.id)) if user
      raise CheckoutError, ACTIVE_CHECKOUT_EXISTS if same_buyer.exists?
      return if @checkout_ip_digest.blank?

      requested = selections.sum { |selection| selection[:quantity] }
      held_cap = per_ip_cap("HAFAPASS_MAX_HELD_TICKETS_PER_IP", DEFAULT_MAX_HELD_TICKETS_PER_IP)
      if held_cap
        # Live holds only: an expired or released hold no longer counts.
        held = InventoryHold.current.joins(:order)
          .where(event_id: event.id, orders: { checkout_ip_digest: @checkout_ip_digest }).sum(:quantity)
        if held + requested > held_cap
          report_cap_denial!("held_tickets_per_ip", cap: held_cap, counted: held, requested: requested)
          raise CheckoutError, NETWORK_HOLD_LIMIT
        end
      end
      free_cap = per_ip_cap("HAFAPASS_MAX_FREE_TICKETS_PER_IP", DEFAULT_MAX_FREE_TICKETS_PER_IP)
      return unless free_cap && totals[:total_cents].zero?

      issued = Ticket.joins(:order).where(event_id: event.id, status: [:issued, :checked_in])
        .where("tickets.created_at > ?", FREE_TICKET_WINDOW.ago)
        .where(orders: { checkout_ip_digest: @checkout_ip_digest, total_cents: 0 }).count
      return unless issued + requested > free_cap

      report_cap_denial!("free_tickets_per_ip", cap: free_cap, counted: issued, requested: requested)
      raise CheckoutError, NETWORK_FREE_LIMIT
    end

    # A positive integer sets the cap; 0 turns it off. Anything else keeps the default.
    def per_ip_cap(name, default)
      value = Integer(ENV.fetch(name, default.to_s), exception: false)
      value = default if value.nil? || value.negative?

      value.positive? ? value : nil
    end

    # Every denial is logged; Sentry hears about each cap and event at most
    # once per CAP_ALERT_INTERVAL per process, so a busy venue cannot flood it.
    def report_cap_denial!(cap_name, cap:, counted:, requested:)
      details = { event: "checkout_network_cap_denied", cap: cap_name, limit: cap, counted: counted,
        requested: requested, event_id: event.id, network_digest_prefix: @checkout_ip_digest.to_s.first(12) }
      Rails.logger.warn(details.to_json)
      return unless self.class.cap_alert_due?([cap_name, event.id])

      Sentry.capture_message("Checkout network cap denied a buyer", level: :warning,
        fingerprint: ["checkout-network-cap", cap_name], extra: details.except(:event))
    rescue StandardError => e
      Rails.logger.error({ event: "checkout_network_cap_report_failed", error_class: e.class.name }.to_json)
    end

    def enforce_pricing_tier_capacity!(tier, requested_quantity, offer: nil, reserved_seat_quantity: 0)
      reserved_offer_quantity = offer&.pricing_tier_id == tier.id ? offer.quantity : 0
      remaining = [tier.quantity_limit - tier.quantity_sold - tier.inventory_holds.current.sum(:quantity) -
        tier.waitlist_offers.holding_inventory.sum(:quantity) - tier.active_seat_holds_quantity(Time.current) +
        reserved_offer_quantity + reserved_seat_quantity, 0].max
      return if requested_quantity <= remaining

      noun = "ticket".pluralize(remaining)
      verb = remaining == 1 ? "remains" : "remain"
      raise CheckoutError, "Only #{remaining} #{noun} #{verb} at the #{tier.name} price"
    end

    def enforce_event_capacity!(requested_quantity, offer: nil)
      return if event.max_capacity.blank?

      sold = event.ticket_types.sum(:quantity_sold)
      held = event.inventory_holds.current.sum(:quantity)
      offered = event.waitlist_offers.holding_inventory.sum(:quantity) - (offer&.quantity || 0)
      active_seat_holds = SeatHold.status_active.joins(:seat_hold_session, :event_seat)
        .where(event_seats: { event_seating_configuration_id: event.event_seating_configuration&.id })
        .where(seat_hold_sessions: { status: SeatHoldSession.statuses[:active] })
        .where("seat_hold_sessions.expires_at > ?", Time.current).count
      reserved_seats = seat_hold_token.present? ? seat_hold_session_for_checkout.seat_holds.status_active.count : 0
      remaining = [event.max_capacity - sold - held - offered - active_seat_holds + reserved_seats, 0].max
      raise CheckoutError, "Only #{remaining} tickets remain within event capacity" if requested_quantity > remaining
    end

    def calculate_totals(selections, catalog_selections)
      ticket_subtotal_cents = selections.sum { |selection| selection[:unit_price_cents] * selection[:quantity] }
      catalog_subtotal_cents = catalog_selections.sum do |selection|
        selection[:unit_price_cents] * selection[:quantity]
      end
      subtotal_cents = ticket_subtotal_cents + catalog_subtotal_cents
      settings = SiteSetting.instance
      # Commerce::ServiceFee prices each ticket exactly as public listings
      # advertise it: percent of the selected unit price (tier or seat price,
      # before any promo discount) rounded per ticket, plus the flat fee per
      # paid ticket, then the event's buyer share. Free and complimentary
      # tickets carry no fee; a promo-discounted ticket is still a paid ticket.
      # Orders created without a service fee (box office, comps) carry none.
      fee_terms = ServiceFee.terms(settings)
      selections.each do |selection|
        selection[:fee_quote] = if service_fee
          ServiceFee.for_event(event, selection[:unit_price_cents], terms: fee_terms)
        else
          ServiceFee.quote(unit_price_cents: 0, buyer_fee_percent: 0, terms: fee_terms)
        end
      end
      paid_ticket_count = selections.sum { |selection| selection[:unit_price_cents].positive? ? selection[:quantity] : 0 }
      platform_fee_cents = selections.sum { |selection| selection[:fee_quote].platform_fee_cents * selection[:quantity] }
      buyer_fee_cents = selections.sum { |selection| selection[:fee_quote].buyer_fee_cents * selection[:quantity] }
      organizer_fee_cents = platform_fee_cents - buyer_fee_cents
      promo_code = locked_promo_code(ticket_subtotal_cents)
      discount_cents = promo_code ? promo_code.calculate_discount(ticket_subtotal_cents) : 0

      {
        subtotal_cents: subtotal_cents,
        ticket_subtotal_cents: ticket_subtotal_cents,
        catalog_subtotal_cents: catalog_subtotal_cents,
        service_fee_cents: buyer_fee_cents,
        platform_fee_cents: platform_fee_cents,
        organizer_fee_cents: organizer_fee_cents,
        discount_cents: discount_cents,
        total_cents: [subtotal_cents + buyer_fee_cents - discount_cents, 0].max,
        promo_code: promo_code,
        # Read once with the fee terms so the order's fee and its processing
        # bearer always come from the same settings snapshot. Orders created
        # without a service fee (box office, comps, guest list) earn no fee to
        # cover processing, so the organizer bears it.
        processing_fee_bearer: service_fee ? settings.processing_fee_bearer : "organizer",
        service_fee_percent: settings.service_fee_percent,
        service_fee_flat_cents: settings.service_fee_flat_cents,
        paid_ticket_count: paid_ticket_count
      }
    end

    def locked_promo_code(subtotal_cents)
      return if promo_code_id.blank? && @promo_code_input.blank?
      raise CheckoutError, PROMO_CODE_REQUIRED unless @promo_code_input.is_a?(String) && @promo_code_input.strip.present?

      # Same normalization as PromoCode#normalize_code and the validate endpoint.
      promo = event.promo_codes.lock.find_by(code: @promo_code_input.strip.upcase)
      promo = nil if promo && promo_code_id.present? && promo.id.to_s != promo_code_id.to_s
      unless promo&.usable? && (!promo.max_uses || promo.reserved_and_finalized_uses < promo.max_uses) &&
          promo.calculate_discount(subtotal_cents).positive?
        raise CheckoutError, "Promo code is no longer available"
      end

      promo
    end

    def create_ledger!(order, selections, catalog_selections, totals, expires_at)
      ticket_subtotals = selections.map { |selection| selection[:unit_price_cents] * selection[:quantity] }
      discounts = MoneyAllocator.call(totals[:discount_cents], ticket_subtotals)
      # Each line carries exactly its own tickets' fees, so a refund of one
      # ticket type returns the fee that was advertised and charged on it.
      buyer_fees = selections.map { |selection| selection[:fee_quote].buyer_fee_cents * selection[:quantity] }
      organizer_fees = selections.map { |selection| selection[:fee_quote].organizer_fee_cents * selection[:quantity] }

      selections.each_with_index do |selection, index|
        subtotal = ticket_subtotals[index]
        item = order.order_items.create!(
          ticket_type: selection[:ticket_type],
          pricing_tier: selection[:pricing_tier],
          item_kind: :ticket,
          name: selection[:ticket_type].name,
          tier_name: selection[:pricing_tier]&.name,
          unit_price_cents: selection[:unit_price_cents],
          quantity: selection[:quantity],
          subtotal_cents: subtotal,
          discount_cents: discounts[index],
          fee_cents: buyer_fees[index],
          organizer_fee_cents: organizer_fees[index],
          tax_cents: 0,
          organizer_proceeds_cents: [subtotal - discounts[index] - organizer_fees[index], 0].max,
          currency: order.currency
        )
        order.inventory_holds.create!(
          order_item: item,
          event: event,
          ticket_type: selection[:ticket_type],
          pricing_tier: selection[:pricing_tier],
          quantity: selection[:quantity],
          expires_at: expires_at
        )
      end

      catalog_selections.each do |selection|
        catalog_item = selection[:catalog_item]
        subtotal = selection[:unit_price_cents] * selection[:quantity]
        item = order.order_items.create!(
          catalog_item: catalog_item,
          item_kind: catalog_item.kind,
          name: catalog_item.name,
          unit_price_cents: selection[:unit_price_cents],
          quantity: selection[:quantity],
          subtotal_cents: subtotal,
          discount_cents: 0,
          fee_cents: 0,
          organizer_fee_cents: 0,
          tax_cents: 0,
          organizer_proceeds_cents: subtotal,
          currency: order.currency
        )
        item.create_catalog_fulfillment! unless catalog_item.donation?
        order.catalog_item_holds.create!(
          order_item: item,
          catalog_item: catalog_item,
          quantity: selection[:quantity],
          expires_at: expires_at
        )
      end

      order.fee_components.create!(
        kind: "platform",
        amount_cents: totals[:platform_fee_cents],
        currency: order.currency,
        estimated: true,
        metadata: {
          percent: totals[:service_fee_percent].to_s,
          flat_cents_per_ticket: totals[:service_fee_flat_cents],
          paid_ticket_count: totals[:paid_ticket_count],
          rounding: ServiceFee::ROUNDING,
          processing_fee_bearer: totals[:processing_fee_bearer],
          fee_policy: event.fee_policy,
          buyer_paid_cents: totals[:service_fee_cents],
          organizer_absorbed_cents: totals[:organizer_fee_cents]
        }
      )
    end

    def validate_registration!
      raise CheckoutError, "registration_answers must be an object" unless registration_answers.respond_to?(:key?)
      raise CheckoutError, "waiver_acceptances must be an array" unless waiver_acceptances.is_a?(Array)

      event.registration_questions.published.each do |question|
        answer = answer_for(question.id)
        raise CheckoutError, "Invalid answer for #{question.prompt}" unless question.valid_answer?(answer)
      end

      accepted = waiver_acceptances.index_by { |value| (value[:event_waiver_id] || value["event_waiver_id"]).to_i }
      event.event_waivers.published.each do |waiver|
        supplied = accepted[waiver.id]
        next if !waiver.required? && supplied.blank?

        version = supplied && (supplied[:version] || supplied["version"])
        unless supplied && ActiveSupport::SecurityUtils.secure_compare(waiver.version, version.to_s)
          raise CheckoutError, "You must accept the current version of #{waiver.title}"
        end
      end
    end

    def record_registration!(order)
      event.registration_questions.published.each do |question|
        answer = answer_for(question.id)
        next if answer.nil? || answer == ""

        order.registration_responses.create!(
          registration_question: question,
          prompt_snapshot: question.prompt,
          kind_snapshot: RegistrationQuestion.kinds.fetch(question.kind),
          required_snapshot: question.required,
          options_snapshot: question.options,
          answer: { "value" => answer },
          answered_at: Time.current
        )
      end

      accepted = waiver_acceptances.index_by { |value| (value[:event_waiver_id] || value["event_waiver_id"]).to_i }
      event.event_waivers.published.each do |waiver|
        next unless accepted[waiver.id]

        order.waiver_acceptances.create!(
          event_waiver: waiver,
          version: waiver.version,
          content_digest: waiver.content_digest,
          accepted_at: Time.current
        )
      end
    end

    def answer_for(question_id)
      registration_answers[question_id] || registration_answers[question_id.to_s]
    end

    def locked_promoter
      return if referral_code.blank?

      promoter = event.promoters.lock.find_by(code: referral_code.to_s.strip.upcase, active: true)
      raise CheckoutError, "Referral code is invalid" unless promoter

      promoter
    end

    def record_referral!(order, promoter)
      return unless promoter

      order.create_referral_attribution!(
        promoter: promoter,
        code_snapshot: promoter.code,
        source: attribution_value(:source),
        medium: attribution_value(:medium),
        campaign: attribution_value(:campaign),
        attributed_at: Time.current
      )
    end

    def attribution_value(key)
      (attribution[key] || attribution[key.to_s]).to_s.strip.presence&.first(255)
    end

    def record_acquisition!(order)
      return if order.source == "box_office"

      event_referral = EventReferral.find_by(code: attribution_value(:event_referral_code).to_s.upcase, event: event,
        active: true)
      link = DistributionLink.available.find_by(code: attribution_value(:distribution_code).to_s.upcase, event: event) unless event_referral
      visitor_hash = begin
        Marketplace::VisitorIdentity.hash(attribution_value(:anonymous_id))
      rescue Marketplace::VisitorIdentity::InvalidIdentifier
        OpenSSL::HMAC.hexdigest("SHA256", Rails.application.secret_key_base, "order/#{order.id}")
      end
      source_value, medium_value, campaign_value = acquisition_values(link, event_referral)

      order.create_acquisition_attribution!(
        distribution_link: link,
        event_referral: event_referral,
        visitor_hash: visitor_hash,
        source: source_value,
        medium: medium_value,
        campaign: campaign_value,
        attributed_at: Time.current
      )
    end

    def acquisition_values(link, event_referral)
      return ["user_referral", "share", event_referral.code] if event_referral
      return [link.distribution_partner.kind, "partner", link.campaign] if link

      [tracking_value(:source) || "direct", tracking_value(:medium) || "none", tracking_value(:campaign)]
    end

    def tracking_value(key)
      value = attribution_value(key)&.first(100)
      value if value&.match?(/\A[a-zA-Z0-9._-]+\z/)
    end

    def reserve_promo!(order, promo_code, discount_cents, expires_at)
      return unless promo_code && discount_cents.positive?

      order.create_promo_redemption!(
        promo_code: promo_code,
        status: :reserved,
        discount_cents: discount_cents,
        expires_at: expires_at
      )
    end

    def create_provider_payment!(order, payment)
      return unless payment&.provider == "stripe" && payment.pending?

      intent = nil
      policy_error = nil
      previously_unknown = false
      lease_token = SecureRandom.uuid
      action = Order.transaction do
        # Commit one setup owner before network activity. Same-key retries must
        # not compete at Stripe, and cancellation/expiry must not wait on HTTP.
        order.lock!
        payment.lock!
        next :done unless order.pending? && payment.pending?
        next :expire if order.expires_at.present? && order.expires_at <= Time.current
        next :recover if payment.provider_payment_id.present?

        payload = payment.provider_payload.to_h
        if payload["setup_lease_expires_at"].present? && Time.iso8601(payload["setup_lease_expires_at"]) > Time.current
          raise CheckoutError, "Payment setup is still in progress; retry the original checkout request"
        end
        previously_unknown = payload["setup_attempted_at"].present? || payment.failure_code == "payment_setup_result_unknown"
        payment.update!(provider_payload: payload.merge("setup_lease_token" => lease_token,
          "setup_lease_expires_at" => SETUP_LEASE_DURATION.from_now.iso8601(6),
          "setup_attempted_at" => payload["setup_attempted_at"] || Time.current.iso8601(6)))
        :create
      end
      return PaymentRecovery.call(order: order).payment_intent if action == :recover
      if action == :expire
        OrderLifecycle.expire!(order)
        return
      end
      return unless action == :create

      intent = Timeout.timeout(PROVIDER_REQUEST_TIMEOUT) do
        StripeService.create_payment_intent(order, idempotency_key: payment.idempotency_key, payment: payment)
      end
      disposition = Order.transaction do
        order.lock!
        payment.lock!
        unless payment.provider_payload.to_h["setup_lease_token"] == lease_token
          raise CheckoutError, "Payment setup ownership changed; retry the original checkout request"
        end
        payment.update!(provider_payment_id: intent.id,
          provider_payload: payment.provider_payload.to_h.except("setup_lease_token", "setup_lease_expires_at")
            .merge("client_secret_present" => intent.client_secret.present?),
          failure_code: nil, failure_message: nil)
        order.update!(stripe_payment_intent_id: intent.id)
        next :cancel unless order.pending? && payment.pending?
        next :expire if order.expires_at.present? && order.expires_at <= Time.current

        unless payment.provider_environment == "simulate" || StripeService.card_only_intent?(intent)
          StripeService.record_card_policy_mismatch!(payment)
          policy_error = "Payment method configuration needs support review; retry your saved checkout instead of creating another order"
        end
        :ready
      end
      if disposition == :cancel
        cancel_unattached_provider_payment!(order, payment, intent, OrderLifecycle::InvalidTransition.new("Reservation released during setup"))
        return
      elsif disposition == :expire
        OrderLifecycle.expire!(order)
        return
      end
      raise CheckoutError, policy_error if policy_error

      intent if order.reload.pending? && payment.reload.pending?
    rescue ActiveRecord::ActiveRecordError => e
      raise CheckoutError, "Saved payment recovery is unavailable; retry the original checkout request" unless action == :create

      cancel_unattached_provider_payment!(order, payment, intent, e)
      finish_failed_provider_setup!(order, payment, lease_token, e, rejected: true)
      raise CheckoutError, "Payment setup failed"
    rescue Stripe::InvalidRequestError, Stripe::CardError, StripeService::PaymentError => e
      finish_failed_provider_setup!(order, payment, lease_token, e, rejected: !previously_unknown)
      message = previously_unknown ? "Payment setup result is unknown; retry the original checkout request" : "Payment setup failed"
      raise CheckoutError, message
    rescue Stripe::StripeError, IOError, Timeout::Error => e
      finish_failed_provider_setup!(order, payment, lease_token, e, rejected: false)
      raise CheckoutError, "Payment setup result is unknown; retry the original checkout request"
    end

    def finish_failed_provider_setup!(order, payment, lease_token, error, rejected:)
      fail_order = false
      Order.transaction do
        order.lock!
        payment.lock!
        payload = payment.provider_payload.to_h
        next unless payment.provider_payment_id.blank? && payload["setup_lease_token"] == lease_token

        payment.update!(provider_payload: payload.except("setup_lease_token", "setup_lease_expires_at"))
        if rejected
          fail_order = true
        elsif order.pending? && payment.pending?
          payment.update!(failure_code: "payment_setup_result_unknown", failure_message: error.message)
        end
      end
      if fail_order
        OrderLifecycle.fail!(order, payment: payment, failure_code: "payment_setup_failed", failure_message: error.message,
          reason: "payment_setup_failed")
      end
    end

    def cancel_unattached_provider_payment!(order, payment, intent, attachment_error)
      return unless intent&.id

      Timeout.timeout(PROVIDER_REQUEST_TIMEOUT) do
        StripeService.cancel_payment_intent(intent.id, idempotency_key: "cancel:payment-setup:#{payment.id}", payment: payment)
      end
    rescue Stripe::StripeError, StripeService::PaymentError, IOError, Timeout::Error => e
      ReconciliationException.create!(
        order: order,
        payment: payment,
        code: "provider_payment_orphaned",
        details: {
          provider_payment_id: intent.id,
          attachment_error_class: attachment_error.class.name,
          cancellation_error_class: e.class.name
        }
      )
      Sentry.capture_exception(e)
    end
  end
end
