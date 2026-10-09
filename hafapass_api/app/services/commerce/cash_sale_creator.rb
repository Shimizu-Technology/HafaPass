# frozen_string_literal: true

module Commerce
  class CashSaleCreator
    class Conflict < StandardError; end

    Result = Data.define(:order, :replayed)

    def self.call(**)
      new(**).call
    end

    def initialize(event:, user:, parameters:, idempotency_key:)
      @event = event
      @user = user
      @parameters = parameters.to_h.deep_stringify_keys
      @key = idempotency_key.presence
    end

    def call
      raise OrderCreator::CheckoutError, "Idempotency-Key is too long" if key && key.bytesize > 255

      # The receipt, capture, inventory and tickets commit together. A crash
      # cannot leave a completed sale without the identity needed to recover it.
      event.with_lock do
        existing = Order.find_by(cash_sale_key: key) if key
        next replay(existing) if existing

        order = OrderCreator.call(
          event: event,
          user: user,
          line_items: parameters["line_items"],
          buyer_name: parameters["buyer_name"].presence || "Walk-in",
          buyer_email: parameters["buyer_email"].presence || "walkin-#{SecureRandom.hex(4)}@boxoffice.local",
          buyer_phone: parameters["buyer_phone"],
          seat_hold_token: parameters["seat_hold_token"],
          payment_required: false,
          service_fee: false,
          source: "box_office",
          payment_method: "door_cash",
          cash_sale_key: key,
          cash_sale_request_digest: key ? request_digest : nil
        ).order
        Result.new(order: order, replayed: false)
      end
    rescue ActiveRecord::RecordNotUnique
      # Different events hold different row locks. The global unique index is
      # the final guard; its losing transaction has already rolled back.
      existing = Order.find_by(cash_sale_key: key) if key
      raise unless existing

      replay(existing)
    end

    private

    attr_reader :event, :user, :parameters, :key

    def replay(order)
      unless order.source == "box_office" && order.payment_method == "door_cash" &&
          order.cash_sale_request_digest == request_digest
        raise Conflict, "Idempotency-Key was already used for a different sale"
      end

      Result.new(order: order, replayed: true)
    end

    def request_digest
      @request_digest ||= begin
        requested = parameters.slice("line_items", "buyer_name", "buyer_email", "buyer_phone", "payment_method")
        requested["seat_hold_digest"] = Digest::SHA256.hexdigest(parameters["seat_hold_token"].to_s)
        identity = { "event_id" => event.id, "organization_id" => event.organization_id, "user_id" => user.id,
                     "request" => requested }
        Digest::SHA256.hexdigest(JSON.generate(canonical(identity)))
      end
    end

    def canonical(value)
      case value
      when Hash then value.keys.sort.to_h { |name| [name, canonical(value[name])] }
      when Array then value.map { |entry| canonical(entry) }
      else value
      end
    end
  end
end
