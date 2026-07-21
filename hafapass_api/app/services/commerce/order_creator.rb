# frozen_string_literal: true

module Commerce
  class OrderCreator
    HOLD_DURATION = 10.minutes

    class CheckoutError < StandardError; end

    Result = Data.define(:order, :payment, :payment_intent, :guest_access_token)

    def self.call(**)
      new(**).call
    end

    def initialize(event:, line_items:, buyer_email:, buyer_name:, buyer_phone: nil, user: nil, promo_code_id: nil,
      payment_required: nil, service_fee: true, complimentary: false, source: nil, payment_method: nil,
      payment_provider: nil, buyer_terms_version: nil, buyer_terms_digest: nil, buyer_terms_accepted_at: nil,
      catalog_items: nil, registration_answers: nil, waiver_acceptances: nil, referral_code: nil,
      attribution: nil, waitlist_offer_token: nil)
      @event = event
      @line_items = line_items
      @buyer_email = buyer_email
      @buyer_name = buyer_name
      @buyer_phone = buyer_phone
      @user = user
      @promo_code_id = promo_code_id
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
    end

    def call
      requires_payment = payment_required.nil? ? StripeService.payment_enabled? : payment_required
      order = nil
      payment = nil

      Order.transaction do
        event.lock!
        raise CheckoutError, "This event is not currently on sale" unless event.sales_open?
        offer = claimable_waitlist_offer!
        offer&.update!(status: :claimed, claimed_at: Time.current)
        selections = locked_selections!(offer: offer)
        catalog_selections = locked_catalog_selections!
        enforce_event_capacity!(selections.sum { |selection| selection[:quantity] }, offer: offer)
        validate_registration!
        promoter = locked_promoter
        totals = calculate_totals(selections, catalog_selections)
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
          source: source,
          payment_method: payment_method,
          buyer_terms_version: buyer_terms_version,
          buyer_terms_digest: buyer_terms_digest,
          buyer_terms_accepted_at: buyer_terms_accepted_at,
          fee_policy_snapshot: event.fee_policy,
          buyer_fee_percent_snapshot: event.buyer_fee_percent,
          organizer_fee_cents: totals[:organizer_fee_cents],
          expires_at: expires_at
        )

        create_ledger!(order, selections, catalog_selections, totals, expires_at)
        reserve_promo!(order, totals[:promo_code], totals[:discount_cents], expires_at)
        record_registration!(order)
        record_referral!(order, promoter)
        offer&.update!(order: order)

        if requires_payment && order.total_cents.positive?
          provider = payment_provider.presence || "stripe"
          payment = order.payments.create!(
            provider: provider,
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
            status: :pending
          )
          OrderLifecycle.complete!(
            order,
            payment: payment,
            provider_amount_cents: payment.amount_cents,
            provider_currency: payment.currency
          )
        else
          OrderLifecycle.complete!(order)
        end
      end

      intent = create_provider_payment!(order, payment)
      order.reload
      guest_access_token = GuestOrderAccess.issue!(order) if order.user_id.nil?
      Result.new(order: order, payment: payment&.reload, payment_intent: intent, guest_access_token: guest_access_token)
    rescue ActiveRecord::RecordInvalid => e
      raise CheckoutError, e.record.errors.full_messages.to_sentence
    end

    private

    attr_reader :event, :line_items, :buyer_email, :buyer_name, :buyer_phone, :user, :promo_code_id,
      :payment_required, :service_fee, :complimentary, :source, :payment_method, :payment_provider
    attr_reader :buyer_terms_version, :buyer_terms_digest, :buyer_terms_accepted_at
    attr_reader :catalog_items, :registration_answers, :waiver_acceptances, :referral_code, :attribution,
      :waitlist_offer_token

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
      enforce_offer_selection!(offer) if offer
      normalized_quantities.sort.map do |ticket_type_id, quantity|
        ticket_type = event.ticket_types.lock.find_by(id: ticket_type_id)
        raise CheckoutError, "Ticket type #{ticket_type_id} not found for this event" unless ticket_type
        raise CheckoutError, "#{ticket_type.name} is not currently on sale" unless ticket_type.on_sale?
        available = ticket_type.available_quantity + (offer&.ticket_type_id == ticket_type.id ? offer.quantity : 0)
        if quantity > available
          raise CheckoutError, "Only #{available} tickets available for #{ticket_type.name}"
        end
        if ticket_type.max_per_order && quantity > ticket_type.max_per_order
          raise CheckoutError, "Maximum #{ticket_type.max_per_order} tickets per order for #{ticket_type.name}"
        end
        enforce_door_allocation!(ticket_type, quantity) if source == "box_office"
        enforce_buyer_limit!(ticket_type, quantity)

        tier = complimentary ? nil : ticket_type.active_pricing_tier
        tier&.lock!
        enforce_pricing_tier_capacity!(tier, quantity, offer: offer) if tier&.quantity_based?
        selection = {
          ticket_type: ticket_type,
          pricing_tier: tier,
          unit_price_cents: complimentary ? 0 : (tier&.price_cents || ticket_type.price_cents),
          quantity: quantity
        }
        if offer
          selection[:pricing_tier] = offer.pricing_tier
          selection[:unit_price_cents] = offer.unit_price_cents
        end
        selection
      end
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

      offer.lock!
      unless offer.active? && offer.event_id == event.id &&
          offer.waitlist_entry.email.casecmp?(buyer_email.to_s.strip)
        raise CheckoutError, "This waitlist offer is invalid or expired"
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

    def enforce_door_allocation!(ticket_type, requested_quantity)
      remaining = ticket_type.door_available_quantity
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

    def enforce_pricing_tier_capacity!(tier, requested_quantity, offer: nil)
      reserved_offer_quantity = offer&.pricing_tier_id == tier.id ? offer.quantity : 0
      remaining = [tier.quantity_limit - tier.quantity_sold - tier.inventory_holds.current.sum(:quantity) -
        tier.waitlist_offers.holding_inventory.sum(:quantity) + reserved_offer_quantity, 0].max
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
      remaining = [event.max_capacity - sold - held - offered, 0].max
      raise CheckoutError, "Only #{remaining} tickets remain within event capacity" if requested_quantity > remaining
    end

    def calculate_totals(selections, catalog_selections)
      ticket_subtotal_cents = selections.sum { |selection| selection[:unit_price_cents] * selection[:quantity] }
      catalog_subtotal_cents = catalog_selections.sum do |selection|
        selection[:unit_price_cents] * selection[:quantity]
      end
      subtotal_cents = ticket_subtotal_cents + catalog_subtotal_cents
      settings = SiteSetting.instance
      ticket_count = selections.sum { |selection| selection[:quantity] }
      platform_fee_cents = if service_fee && ticket_subtotal_cents.positive?
        (ticket_subtotal_cents * (settings.service_fee_percent / 100.0)).round +
          (ticket_count * settings.service_fee_flat_cents)
      else
        0
      end
      buyer_fee_cents = (platform_fee_cents * event.buyer_fee_percent / 100.0).round
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
        promo_code: promo_code
      }
    end

    def locked_promo_code(subtotal_cents)
      return if promo_code_id.blank?

      promo = event.promo_codes.lock.find_by(id: promo_code_id)
      unless promo&.usable? && (!promo.max_uses || promo.reserved_and_finalized_uses < promo.max_uses) &&
          promo.calculate_discount(subtotal_cents).positive?
        raise CheckoutError, "Promo code is no longer available"
      end

      promo
    end

    def create_ledger!(order, selections, catalog_selections, totals, expires_at)
      ticket_subtotals = selections.map { |selection| selection[:unit_price_cents] * selection[:quantity] }
      discounts = MoneyAllocator.call(totals[:discount_cents], ticket_subtotals)
      buyer_fees = MoneyAllocator.call(totals[:service_fee_cents], ticket_subtotals)
      organizer_fees = MoneyAllocator.call(totals[:organizer_fee_cents], ticket_subtotals)

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
          percent: SiteSetting.instance.service_fee_percent.to_s,
          flat_cents_per_ticket: SiteSetting.instance.service_fee_flat_cents,
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
      return unless payment&.provider == "stripe"

      intent = StripeService.create_payment_intent(order, idempotency_key: payment.idempotency_key)
      Payment.transaction do
        payment.lock!
        payment.update!(provider_payment_id: intent.id, provider_payload: { client_secret_present: intent.client_secret.present? })
        order.update!(stripe_payment_intent_id: intent.id)
      end
      intent
    rescue ActiveRecord::ActiveRecordError => e
      cancel_unattached_provider_payment!(order, payment, intent, e)
      OrderLifecycle.fail!(order, payment: payment, failure_code: "payment_setup_failed", failure_message: e.message,
        reason: "payment_setup_failed")
      raise CheckoutError, "Payment setup failed"
    rescue Stripe::StripeError, StripeService::PaymentError => e
      OrderLifecycle.fail!(order, payment: payment, failure_code: "payment_setup_failed", failure_message: e.message,
        reason: "payment_setup_failed")
      raise CheckoutError, "Payment setup failed"
    end

    def cancel_unattached_provider_payment!(order, payment, intent, attachment_error)
      return unless intent&.id

      StripeService.cancel_payment_intent(intent.id, idempotency_key: "cancel:payment-setup:#{payment.id}")
    rescue Stripe::StripeError, StripeService::PaymentError => e
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
