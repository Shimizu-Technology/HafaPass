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
      payment_required: nil, service_fee: true, complimentary: false, source: nil, payment_method: nil)
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
    end

    def call
      requires_payment = payment_required.nil? ? StripeService.payment_enabled? : payment_required
      order = nil
      payment = nil

      Order.transaction do
        event.lock!
        raise CheckoutError, "This event is not currently on sale" unless event.sales_open?
        selections = locked_selections!
        enforce_event_capacity!(selections.sum { |selection| selection[:quantity] })
        totals = calculate_totals(selections)
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
          expires_at: expires_at
        )

        create_ledger!(order, selections, totals, expires_at)
        reserve_promo!(order, totals[:promo_code], totals[:discount_cents], expires_at)

        if requires_payment && order.total_cents.positive?
          payment = order.payments.create!(
            provider: "stripe",
            idempotency_key: "payment:order:#{order.id}",
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
      :payment_required, :service_fee, :complimentary, :source, :payment_method

    def normalized_quantities
      raise CheckoutError, "line_items is required and must be a non-empty array" unless line_items.is_a?(Array) && line_items.any?

      line_items.each_with_object(Hash.new(0)) do |item, quantities|
        ticket_type_id = item[:ticket_type_id] || item["ticket_type_id"]
        quantity = (item[:quantity] || item["quantity"]).to_i
        raise CheckoutError, "Quantity must be greater than 0" unless quantity.positive?

        quantities[ticket_type_id.to_i] += quantity
      end
    end

    def locked_selections!
      normalized_quantities.sort.map do |ticket_type_id, quantity|
        ticket_type = event.ticket_types.lock.find_by(id: ticket_type_id)
        raise CheckoutError, "Ticket type #{ticket_type_id} not found for this event" unless ticket_type
        raise CheckoutError, "#{ticket_type.name} is not currently on sale" unless ticket_type.on_sale?
        if quantity > ticket_type.available_quantity
          raise CheckoutError, "Only #{ticket_type.available_quantity} tickets available for #{ticket_type.name}"
        end
        if ticket_type.max_per_order && quantity > ticket_type.max_per_order
          raise CheckoutError, "Maximum #{ticket_type.max_per_order} tickets per order for #{ticket_type.name}"
        end
        enforce_buyer_limit!(ticket_type, quantity)

        tier = complimentary ? nil : ticket_type.active_pricing_tier
        tier&.lock!
        enforce_pricing_tier_capacity!(tier, quantity) if tier&.quantity_based?
        {
          ticket_type: ticket_type,
          pricing_tier: tier,
          unit_price_cents: complimentary ? 0 : (tier&.price_cents || ticket_type.price_cents),
          quantity: quantity
        }
      end
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

    def enforce_pricing_tier_capacity!(tier, requested_quantity)
      remaining = [tier.quantity_limit - tier.quantity_sold - tier.inventory_holds.current.sum(:quantity), 0].max
      return if requested_quantity <= remaining

      noun = "ticket".pluralize(remaining)
      verb = remaining == 1 ? "remains" : "remain"
      raise CheckoutError, "Only #{remaining} #{noun} #{verb} at the #{tier.name} price"
    end

    def enforce_event_capacity!(requested_quantity)
      return if event.max_capacity.blank?

      sold = event.ticket_types.sum(:quantity_sold)
      held = event.inventory_holds.current.sum(:quantity)
      remaining = [event.max_capacity - sold - held, 0].max
      raise CheckoutError, "Only #{remaining} tickets remain within event capacity" if requested_quantity > remaining
    end

    def calculate_totals(selections)
      subtotal_cents = selections.sum { |selection| selection[:unit_price_cents] * selection[:quantity] }
      settings = SiteSetting.instance
      ticket_count = selections.sum { |selection| selection[:quantity] }
      service_fee_cents = if service_fee && subtotal_cents.positive?
        (subtotal_cents * (settings.service_fee_percent / 100.0)).round +
          (ticket_count * settings.service_fee_flat_cents)
      else
        0
      end
      promo_code = locked_promo_code(subtotal_cents)
      discount_cents = promo_code ? promo_code.calculate_discount(subtotal_cents) : 0

      {
        subtotal_cents: subtotal_cents,
        service_fee_cents: service_fee_cents,
        discount_cents: discount_cents,
        total_cents: [subtotal_cents + service_fee_cents - discount_cents, 0].max,
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

    def create_ledger!(order, selections, totals, expires_at)
      subtotals = selections.map { |selection| selection[:unit_price_cents] * selection[:quantity] }
      discounts = MoneyAllocator.call(totals[:discount_cents], subtotals)
      fees = MoneyAllocator.call(totals[:service_fee_cents], subtotals)

      selections.each_with_index do |selection, index|
        subtotal = subtotals[index]
        item = order.order_items.create!(
          ticket_type: selection[:ticket_type],
          pricing_tier: selection[:pricing_tier],
          name: selection[:ticket_type].name,
          tier_name: selection[:pricing_tier]&.name,
          unit_price_cents: selection[:unit_price_cents],
          quantity: selection[:quantity],
          subtotal_cents: subtotal,
          discount_cents: discounts[index],
          fee_cents: fees[index],
          tax_cents: 0,
          organizer_proceeds_cents: subtotal - discounts[index],
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

      order.fee_components.create!(
        kind: "platform",
        amount_cents: totals[:service_fee_cents],
        currency: order.currency,
        estimated: true,
        metadata: {
          percent: SiteSetting.instance.service_fee_percent.to_s,
          flat_cents_per_ticket: SiteSetting.instance.service_fee_flat_cents
        }
      )
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
