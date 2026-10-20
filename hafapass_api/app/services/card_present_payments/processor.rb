# frozen_string_literal: true

module CardPresentPayments
  class Processor
    class ProcessingError < StandardError
      attr_reader :attempt

      def initialize(message, attempt:)
        @attempt = attempt
        super(message)
      end
    end

    UNKNOWN_RESULT_HOLD = 24.hours

    def self.call(**)
      new(**).call
    end

    def initialize(order:, payment:, account:, user:, idempotency_key:, gateway: CardPresentGateway.new, request: nil)
      @order = order
      @payment = payment
      @account = account
      @user = user
      @idempotency_key = idempotency_key.to_s
      @gateway = gateway
      @request = request
    end

    def call
      @new_attempt = false
      attempt = find_or_create_attempt!
      validate_replay!(attempt)
      return attempt if attempt.status_succeeded?
      raise ProcessingError.new(attempt.failure_message.presence || "Card payment failed", attempt: attempt) if attempt.status_failed?
      unless @new_attempt
        # An interrupted/in-flight POST may already have reached the terminal.
        # Persist uncertainty so every caller, including the UI, retains the
        # original operation identity until its outcome is reconciled.
        record_unknown!(attempt, CardPresentGateway::ResultUnknown.new("Card payment requires reconciliation before another submission"), replay: true)
        return attempt if attempt.status_succeeded?

        message = attempt.status_failed? ? attempt.failure_message : "Card payment requires reconciliation before another submission"
        raise ProcessingError.new(message.presence || "Card payment failed", attempt: attempt)
      end

      # A policy hold or sales suspension placed after the order was created
      # stops the charge; the order fails and its inventory is released.
      raise CardPresentGateway::PaymentError, "This event is not currently on sale" unless order.event.reload.sales_open?

      result = gateway.charge(
        account: attempt.card_present_account,
        amount_cents: attempt.amount_cents,
        currency: attempt.currency,
        external_payment_id: attempt.external_payment_id,
        idempotency_key: attempt.idempotency_key
      )
      begin
        record_success!(attempt, result)
      rescue ActiveRecord::ActiveRecordError => e
        record_unknown!(attempt, e, provider_response: result.provider_response,
          provider_payment_id: result.provider_payment_id)
        Sentry.capture_exception(e)
        raise ProcessingError.new("The terminal succeeded but HåfaPass requires reconciliation", attempt: attempt)
      end
    rescue CardPresentGateway::PaymentError => e
      record_failure!(attempt, e)
      raise ProcessingError.new(e.message, attempt: attempt)
    rescue CardPresentGateway::ResultUnknown => e
      record_unknown!(attempt, e)
      raise ProcessingError.new(e.message, attempt: attempt)
    end

    private

    attr_reader :order, :payment, :account, :user, :idempotency_key, :gateway, :request

    def find_or_create_attempt!
      raise ProcessingError.new("Idempotency-Key is required", attempt: nil) if idempotency_key.blank?

      existing = CardPresentPaymentAttempt.find_by(idempotency_key: idempotency_key)
      return adopt_existing_attempt!(existing) if existing

      attempt = with_locked_sale do
        prior = payment.card_present_payment_attempts.order(:id).lock.first
        if prior && prior.idempotency_key != idempotency_key
          raise ProcessingError.new("This payment already has a terminal attempt; use the original Idempotency-Key and reconcile it", attempt: prior)
        end

        CardPresentPaymentAttempt.create!(
          organization: order.event.organization,
          event: order.event,
          order: order,
          payment: payment,
          card_present_account: account,
          initiated_by_user: user,
          provider: account.provider,
          idempotency_key: idempotency_key,
          external_payment_id: external_payment_id,
          amount_cents: payment.amount_cents,
          currency: payment.currency,
          initiated_at: Time.current
        )
      end
      @new_attempt = true
      attempt
    rescue ActiveRecord::RecordNotUnique, ActiveRecord::RecordInvalid => e
      existing = CardPresentPaymentAttempt.find_by(idempotency_key: idempotency_key)
      raise e unless existing

      # Adopt only after the losing reservation transaction has rolled back;
      # never lock two orders in opposite directions for a cross-order replay.
      adopt_existing_attempt!(existing)
    end

    def adopt_existing_attempt!(existing)
      if order.id != existing.order_id
        equivalent = order.event_id == existing.event_id && user.id == existing.initiated_by_user_id &&
          order.user_id == existing.initiated_by_user_id && order.total_cents == existing.amount_cents &&
          line_item_quantities(order) == line_item_quantities(existing.order)
        Commerce::OrderLifecycle.cancel!(order, reason: "duplicate_card_present_request") if order.pending?
        unless equivalent
          raise ProcessingError.new("Idempotency-Key was already used for a different sale", attempt: existing)
        end
      end
      @order = existing.order
      @payment = existing.payment
      @account = existing.card_present_account
      existing
    end

    # Match OrderLifecycle's order -> payment locks before an attempt update or
    # INSERT (whose order foreign key also acquires KEY SHARE). Provider RPCs
    # are deliberately outside every invocation of this helper.
    def with_locked_sale(attempt = nil)
      Order.transaction do
        order.lock!
        payment.lock!
        attempt&.lock!
        yield
      end
    end

    def validate_replay!(attempt)
      valid = attempt.event_id == order.event_id && attempt.organization_id == order.event.organization_id &&
        attempt.initiated_by_user_id == user.id
      raise ProcessingError.new("Idempotency-Key was already used for a different sale", attempt: attempt) unless valid
    end

    def external_payment_id
      "hp_#{Digest::SHA256.hexdigest("#{payment.id}:#{idempotency_key}").first(29)}"
    end

    def line_item_quantities(sale_order)
      sale_order.order_items.group(:ticket_type_id).sum(:quantity)
    end

    def record_success!(attempt, result)
      lifecycle_result = nil
      completed = false
      with_locked_sale(attempt) do
        payment.update!(provider_payment_id: result.provider_payment_id, provider_payload: result.provider_response)
        lifecycle_result = Commerce::OrderLifecycle.complete!(
          order,
          payment: payment,
          provider_amount_cents: result.amount_cents,
          provider_currency: result.currency
        )
        completed = order.reload.completed?
        if completed
          attempt.update!(
            status: :succeeded,
            provider_payment_id: result.provider_payment_id,
            provider_response: result.provider_response,
            completed_at: Time.current,
            failure_code: nil,
            failure_message: nil
          )
          account.update!(last_seen_at: Time.current)
          ReconciliationException.open.where(order: order, payment: payment, code: "card_present_result_unknown").find_each(&:resolve!)
        end
      end

      unless completed
        record_unknown!(attempt, CardPresentGateway::ResultUnknown.new("Payment succeeded but ticket issuance requires reconciliation"),
          provider_response: result.provider_response, provider_payment_id: result.provider_payment_id)
        raise ProcessingError.new("Payment succeeded but ticket issuance requires reconciliation", attempt: attempt)
      end

      audit!("card_present.payment_succeeded", attempt, lifecycle_result: lifecycle_result)
      attempt
    end

    def record_failure!(attempt, error)
      return unless attempt

      changed = false
      with_locked_sale(attempt) do
        next if attempt.status_succeeded? || attempt.status_failed?

        attempt.update!(status: :failed, failure_code: "terminal_payment_failed", failure_message: error.message.first(500),
          completed_at: Time.current)
        Commerce::OrderLifecycle.fail!(order, payment: payment, failure_code: "terminal_payment_failed",
          failure_message: error.message.first(500), reason: "terminal_payment_failed")
        ReconciliationException.open.where(order: order, payment: payment, code: "card_present_result_unknown").find_each(&:resolve!)
        changed = true
      end
      audit!("card_present.payment_failed", attempt, error_class: error.class.name) if changed
    end

    def record_unknown!(attempt, error, provider_response: nil, provider_payment_id: nil, replay: false)
      return unless attempt

      changed = false
      with_locked_sale(attempt) do
        next if attempt.status_succeeded? || attempt.status_failed?
        next if replay && attempt.status_result_unknown?

        attempt.update!(
          status: :result_unknown,
          failure_code: "terminal_result_unknown",
          failure_message: error.message.first(500),
          provider_response: provider_response || attempt.provider_response,
          provider_payment_id: provider_payment_id || attempt.provider_payment_id
        )
        if order.pending?
          extended_expiry = UNKNOWN_RESULT_HOLD.from_now
          order.update!(expires_at: extended_expiry)
          order.inventory_holds.active.update_all(expires_at: extended_expiry, updated_at: Time.current)
        end
        ReconciliationException.open.find_or_create_by!(order: order, payment: payment, code: "card_present_result_unknown") do |exception|
          exception.details = { card_present_payment_attempt_id: attempt.id, external_payment_id: attempt.external_payment_id }
        end
        changed = true
      end
      audit!("card_present.payment_result_unknown", attempt, error_class: error.class.name) if changed
    end

    def audit!(action, attempt, metadata = {})
      AuditLogger.record!(action: action, auditable: attempt, actor: user, organization: attempt.organization,
        metadata: metadata.merge(event_id: attempt.event_id, order_id: attempt.order_id), request: request)
    end
  end
end
