# frozen_string_literal: true

require "timeout"
require "uri"

module Commerce
  class OnlineDoorSale
    class Unavailable < StandardError; end
    class ProviderUnknown < StandardError
      attr_accessor :order_id
    end

    PROVIDER_TIMEOUT = 15.seconds
    SETUP_LEASE_DURATION = 30.seconds

    def self.buyer_email(order)
      order.buyer_email unless order.buyer_email.downcase.end_with?("@boxoffice.local")
    end

    def self.link_available?(order)
      order&.pending? && order.online_door_card? && order.expires_at&.future? &&
        order.payments.sole.stripe_checkout_url.present?
    end

    def self.call(**arguments)
      new(**arguments).call
    end

    def initialize(event:, user:, parameters:, idempotency_key:)
      @event = event
      @user = user
      @parameters = parameters.to_h.deep_stringify_keys
      @key = idempotency_key
    end

    def call
      validate_request!
      key_digest = Digest::SHA256.hexdigest("online-door/#{key}")
      request_digest = Digest::SHA256.hexdigest(JSON.generate(canonical(
        event_id: event.id, seller_id: user.id, parameters: parameters
      )))
      claim = CheckoutAttempt.claim!(key_digest: key_digest, request_digest: request_digest)
      order = claim.attempt.order
      unless order
        begin
          unless event.online_door_card_enabled? && StripeService.payment_enabled? &&
              (!Rails.env.local? || StripeService.payment_mode == "test")
            raise Unavailable, "Online door card sales are unavailable for this event."
          end
          order = reserve!(claim, key_digest, request_digest)
        rescue OrderCreator::CheckoutError, Unavailable, StripeService::PaymentError
          claim.attempt.reject!(claim.lease_token)
          raise
        end
      end
      unless order.online_door_card? && order.event_id == event.id && order.sold_by_id == user.id
        raise CheckoutAttempt::Conflict.new("This checkout belongs to a different sale.", recovery_required: false)
      end

      open_session!(order)
      order.reload
    rescue ProviderUnknown => e
      e.order_id = order&.id
      raise
    end

    def self.cancel!(order)
      payment = order.payments.sole
      return order unless order.pending?

      if payment.stripe_checkout_session_id
        session = Timeout.timeout(PROVIDER_TIMEOUT) do
          StripeService.expire_door_checkout_session(payment: payment, session_id: payment.stripe_checkout_session_id)
        end
        unless session.id == payment.stripe_checkout_session_id && session.livemode == (payment.provider_environment == "live")
          raise ProviderUnknown, "Stripe could not confirm which checkout was closed. Retry this sale."
        end
        # A completed session waits for its signed payment webhook.
        if session.status == "complete"
          payment.update!(stripe_checkout_url: nil)
          return order.reload
        end
        raise ProviderUnknown, "Stripe did not confirm cancellation. Retry this sale." unless session.status == "expired"
      end

      OrderLifecycle.cancel!(order, reason: "box_office_cancelled", closed_checkout_session_id: payment.stripe_checkout_session_id)
      order.reload
    rescue OrderLifecycle::InvalidTransition
      order.reload
    rescue Stripe::StripeError, StripeService::PaymentError, IOError, Timeout::Error
      raise ProviderUnknown, "Could not confirm cancellation. Keep this sale open and try again."
    end

    private

    attr_reader :event, :user, :parameters, :key

    def validate_request!
      unless key.to_s.match?(/\Abox-office-[a-zA-Z0-9-]{16,100}\z/)
        raise OrderCreator::CheckoutError, "A valid Idempotency-Key is required."
      end
      unless Order::ONLINE_DOOR_CARD_METHODS.include?(parameters["payment_method"])
        raise OrderCreator::CheckoutError, "Choose how the buyer will pay."
      end
      unless parameters["line_items"].is_a?(Array) && parameters["line_items"].any?
        raise OrderCreator::CheckoutError, "Select at least one ticket."
      end
      email = parameters["buyer_email"].to_s.strip
      if email.present? && (email.bytesize > 254 || !URI::MailTo::EMAIL_REGEXP.match?(email) || email.downcase.end_with?("@boxoffice.local"))
        raise OrderCreator::CheckoutError, "Enter a valid buyer email."
      end
    end

    def reserve!(claim, key_digest, request_digest)
      OrderCreator.call(
        event: event, sold_by: user, line_items: parameters.fetch("line_items"),
        buyer_name: parameters["buyer_name"].presence || "Walk-in",
        buyer_email: parameters["buyer_email"].to_s.strip.downcase.presence || "walkin-#{SecureRandom.hex(8)}@boxoffice.local",
        buyer_phone: parameters["buyer_phone"], seat_hold_token: parameters["seat_hold_token"],
        registration_answers: parameters["registration_answers"],
        source: "box_office", payment_method: parameters.fetch("payment_method"), payment_provider: "stripe",
        payment_required: true, service_fee: true, checkout_attempt: claim.attempt,
        checkout_key_digest: key_digest, checkout_request_digest: request_digest, checkout_lease_token: claim.lease_token
      ).order
    end

    def open_session!(order)
      payment = order.payments.sole
      expires_at = order.expires_at
      return unless order.pending? && expires_at&.future? && payment.stripe_checkout_session_id.nil?

      # This lease only serializes setup. The Stripe key remains bound to the
      # payment and the request stays unchanged if the owner crashes or times out.
      lease = claim_setup!(payment, expires_at)
      return unless lease

      session = Timeout.timeout(PROVIDER_TIMEOUT) do
        StripeService.create_door_checkout_session(payment: payment, line_items: checkout_lines(order), expires_at: expires_at)
      end
      persist_session!(order, payment, session, expires_at, lease)
      OrderLifecycle.expire!(order, provider_expired: true) if session.status == "expired"
    rescue Stripe::StripeError, StripeService::PaymentError, IOError, Timeout::Error
      raise ProviderUnknown, "Stripe setup could not be confirmed. Retry this saved sale."
    ensure
      release_setup!(payment, lease) if lease
    end

    def claim_setup!(payment, expires_at)
      payment.with_lock do
        payload = payment.provider_payload.to_h
        deadline = payload["door_checkout_setup_lease_expires_at"]
        return if payment.stripe_checkout_session_id.present? || (deadline && Time.iso8601(deadline).future?)

        # The provider requires new Sessions to expire at least 30 minutes out.
        # A later retry may still replay a previously attempted Stripe request.
        attempted_at = payload["door_checkout_setup_attempted_at"]
        if attempted_at.blank? && expires_at < 31.minutes.from_now
          raise ProviderUnknown, "The payment link was never opened. Cancel this sale and start again."
        end
        lease = SecureRandom.uuid
        payment.update!(provider_payload: payload.merge(
          "door_checkout_setup_attempted_at" => attempted_at || Time.current.iso8601,
          "door_checkout_setup_lease" => lease,
          "door_checkout_setup_lease_expires_at" => SETUP_LEASE_DURATION.from_now.iso8601(6)
        ))
        lease
      end
    end

    def release_setup!(payment, lease)
      payment.with_lock do
        payload = payment.provider_payload.to_h
        if payload["door_checkout_setup_lease"] == lease
          payment.update!(provider_payload: payload.except("door_checkout_setup_lease", "door_checkout_setup_lease_expires_at"))
        end
      end
    end

    def persist_session!(order, payment, session, expires_at, lease)
      unless session.id.to_s.match?(/\Acs_#{payment.provider_environment}_[a-zA-Z0-9]+\z/) &&
          session.livemode == (payment.provider_environment == "live") &&
          session.amount_total == payment.amount_cents && session.currency == payment.currency &&
          session.expires_at == expires_at.to_i
        raise ProviderUnknown, "Stripe returned a checkout that could not be verified. Contact support."
      end
      url = session.url if session.status == "open"
      if session.status == "open" && !checkout_url?(url)
        raise ProviderUnknown, "Stripe did not return a verified checkout URL. Contact support."
      end

      order.with_lock do
        payment.lock!
        if payment.provider_payload.to_h["door_checkout_setup_lease"] != lease
          raise ProviderUnknown, "Stripe setup is being recovered. Refresh this saved sale."
        end
        if payment.stripe_checkout_session_id && payment.stripe_checkout_session_id != session.id
          raise ProviderUnknown, "Stripe returned a different checkout. Contact support."
        end
        payment.update!(stripe_checkout_session_id: session.id,
          stripe_checkout_url: order.pending? && expires_at.future? ? url : nil)
      end
    end

    def checkout_url?(value)
      uri = URI.parse(value.to_s)
      uri.is_a?(URI::HTTPS) && uri.host == "checkout.stripe.com" && uri.port == 443 &&
        uri.userinfo.nil? && uri.path.start_with?("/c/pay/")
    rescue URI::InvalidURIError
      false
    end

    def checkout_lines(order)
      lines = order.order_items.order(:id).map do |item|
        checkout_line([item.name, item.tier_name].compact.join(" · "), item.unit_price_cents, item.quantity, order.currency)
      end
      if order.service_fee_cents.positive?
        lines << checkout_line("HåfaPass service fee", order.service_fee_cents, 1, order.currency)
      end
      lines
    end

    def checkout_line(name, amount, quantity, currency)
      { price_data: { currency: currency, unit_amount: amount, product_data: { name: name.first(120) } }, quantity: quantity }
    end

    def canonical(value)
      case value
      when Hash then value.stringify_keys.sort.to_h.transform_values { |entry| canonical(entry) }
      when Array then value.map { |entry| canonical(entry) }
      else value
      end
    end
  end
end
