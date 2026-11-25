# frozen_string_literal: true

require "ostruct"

class StripeWebhookProcessor
  class ProcessingError < StandardError; end

  def self.call(event:, payload:)
    new(event: event, payload: payload).call
  end

  # Refund and dispute notices that found no payment (or a payment that could
  # not record them yet) leave an orphan exception on their receipt.
  ORPHAN_CODES = %w[refund_operation_not_found refunded_payment_not_found disputed_payment_not_found].freeze
  REPLAYABLE_TYPES = StripeReplayableEvents::TYPES

  # Executable replay of stored provider evidence (docs/design/never-
  # fulfilled-captures.md §7.2). Locks the receipt first, then the handlers
  # take the normal refund and dispute prefix (organization -> event ->
  # order). Reads only the stored payload, never refetches, and makes no
  # network call. The stored object must name this payment's intent, mode and
  # account; a mismatch leaves the orphan open. Idempotent per movement: a
  # refund by provider refund ID, a dispute by provider dispute ID and a
  # posting by (kind, source), so a second replay changes nothing.
  def self.replay!(receipt, payment:)
    new(event: Stripe::Event.construct_from(receipt.payload), payload: receipt.payload).send(:replay!, receipt, payment)
  end

  # Receipts whose open orphan exception may describe this payment: by the
  # identity stored with the receipt (kept when retention or a privacy
  # request clears the payload), else by the payload of an older receipt.
  def self.replayable_receipts(payment)
    return WebhookEvent.none if payment.provider_payment_id.blank?

    orphans = ReconciliationException.open.where(code: ORPHAN_CODES)
      .where("reconciliation_exceptions.payment_id IS NULL OR reconciliation_exceptions.payment_id = ?", payment.id)
    WebhookEvent.where(id: orphans.select(:webhook_event_id), event_type: REPLAYABLE_TYPES)
      .merge(naming_intent(payment.provider_payment_id)).order(:id)
  end

  def self.naming_intent(intent_id)
    WebhookEvent.where(provider_payment_intent_id: intent_id)
      .or(WebhookEvent.where(provider_payment_intent_id: nil)
        .where("webhook_events.payload -> 'data' -> 'object' ->> 'payment_intent' = ?", intent_id))
  end

  # The provider identity a signed refund or dispute notice carries, stored
  # outside its payload (A1-R1 review finding 5).
  # A capture notice keeps it too, only when the intent succeeded, so a
  # second capture an older release acknowledged can still be proven after
  # its payload is cleared (the database keeps the same fields when any
  # release clears a payload: hafapass_keep_receipt_identity).
  def self.provider_identity(event_type, payload)
    return {} unless FinancialIntegrity::WEBHOOK_IDENTITY_TYPES.include?(event_type)

    object = payload.to_h.dig("data", "object").to_h
    capture = event_type == "payment_intent.succeeded"
    return {} if capture && object["status"] != "succeeded"

    intent = capture ? object["id"] : object["payment_intent"]
    intent = intent["id"] if intent.is_a?(Hash)
    amount = object["amount_refunded"] if event_type == "charge.refunded"
    amount = object["amount_received"] if capture
    amount ||= object["amount"] unless capture
    { provider_payment_intent_id: intent.presence&.to_s, provider_object_id: object["id"].presence&.to_s,
      provider_livemode: payload.to_h.key?("livemode") ? payload["livemode"] == true : nil,
      provider_account_id: payload.to_h["account"].presence&.to_s,
      provider_amount_cents: amount.is_a?(Integer) ? amount : nil,
      provider_currency: object["currency"].presence&.to_s&.downcase }
  end

  def initialize(event:, payload:)
    @event = event
    @payload = payload
  end

  def call
    receipt = store_receipt!
    if receipt.processed? || receipt.ignored?
      discover_acknowledged_capture!(receipt)
      return receipt
    end

    receipt.update!(status: :processing, attempts: receipt.attempts + 1, last_error: nil)
    AuditContext.set(source: "provider", fail_open: true) { process!(receipt) }
    receipt
  rescue StandardError => e
    receipt&.update!(status: :failed, last_error: "#{e.class}: #{e.message}")
    raise
  end

  private

  attr_reader :event, :payload

  # A capture notice an older release already processed returns early, but
  # if that release acknowledged a second capture without classifying it,
  # this release classifies or quarantines it now (A1-R1 recheck blocker 3).
  def discover_acknowledged_capture!(receipt)
    return unless receipt.processed? && receipt.event_type == StripeReplayableEvents::CAPTURE_TYPE

    payment = receipt.payment_event&.payment
    return unless payment && Commerce::NeverFulfilledReconcile.overlap_capture?(payment)

    Commerce::NeverFulfilledReconcile.call_for_payment(payment, dry_run: false)
  rescue ActiveRecord::ActiveRecordError => e
    # The receipt stays processed; the database keeps the event held and
    # RefundReconciliationJob retries the discovery.
    Rails.logger.error("[StripeWebhookProcessor] overlap capture discovery for receipt #{receipt.id}: #{e.class}")
  end

  def replay!(receipt, payment)
    WebhookEvent.transaction do
      receipt.lock!
      orphans = receipt.reconciliation_exceptions.open.where(code: ORPHAN_CODES)
        .where("payment_id IS NULL OR payment_id = ?", payment.id).order(:id).to_a
      next :nothing unless receipt.processed? && orphans.any? && REPLAYABLE_TYPES.include?(receipt.event_type)

      # A payload that retention or a privacy request cleared has no object.
      object = event.respond_to?(:data) ? event.data&.object : nil
      unless object && replay_context_matches?(payment, object)
        # The stored identity still names this payment (its payload may have
        # been cleared): the orphan stays open, now on this payment and
        # order, so it holds them until finance records it from Stripe.
        bind = stored_identity_matches?(receipt, payment)
        orphans.each do |orphan|
          attributes = { details: orphan.details.to_h.merge("replay_blocked" => "payment_context_mismatch") }
          attributes.merge!(payment: payment, order: payment.order) if bind && orphan.payment_id.nil?
          orphan.update!(attributes)
        end
        next :payment_context_mismatch
      end

      started = Time.current
      AuditContext.set(source: "provider", fail_open: true) do
        case event.type
        when "charge.refunded" then process_refund!(receipt, payment, object)
        when "charge.dispute.created", "charge.dispute.updated", "charge.dispute.closed" then process_dispute!(receipt, payment, object)
        else process_refund_operation!(receipt, payment, object)
        end
      end
      # The handler opened a new item for this receipt: the evidence still
      # cannot be recorded, so the orphan stays open.
      next :unresolved if receipt.reconciliation_exceptions.open.where(payment_id: payment.id)
        .where("created_at >= ?", started).where.not(id: orphans.map(&:id)).exists?

      order = payment.order
      order.event.organization.lock!("FOR NO KEY UPDATE")
      order.event.lock!
      order.lock!
      orphans.each do |orphan|
        orphan.resolve!
        AuditLogger.record!(action: "webhook_event.replayed", auditable: orphan,
          organization: order.event.organization, event: order.event, source: "provider", outcome: "succeeded",
          deduplication_key: "webhook_event:#{receipt.id}:replayed:#{orphan.id}",
          metadata: { code: orphan.code, webhook_event_id: receipt.id, provider_event_id: receipt.provider_event_id,
            event_type: receipt.event_type, payment_id: payment.id, provider_object_id: value(object, :id) })
      end
      receipt.update!(replayed_at: Time.current)
      Commerce::NeverFulfilledResolution.evaluate_payment!(payment.id, trigger: "replay")
      :replayed
    end
  end

  def replay_context_matches?(payment, object)
    %w[test live].include?(payment.provider_environment) &&
      value(object, :payment_intent).present? && value(object, :payment_intent) == payment.provider_payment_id &&
      payload["livemode"] == (payment.provider_environment == "live") &&
      payload["account"].presence == payment.provider_account_id.presence
  end

  def stored_identity_matches?(receipt, payment)
    receipt.provider_payment_intent_id.present? && receipt.provider_payment_intent_id == payment.provider_payment_id &&
      receipt.provider_livemode == (payment.provider_environment == "live") &&
      receipt.provider_account_id.presence == payment.provider_account_id.presence
  end

  def store_receipt!
    WebhookEvent.create!(
      provider: "stripe",
      provider_event_id: event.id,
      event_type: event.type,
      payload: payload,
      provider_created_at: event.respond_to?(:created) && event.created ? Time.zone.at(event.created.to_i) : nil,
      **self.class.provider_identity(event.type, payload.respond_to?(:to_unsafe_h) ? payload.to_unsafe_h : payload.to_h.deep_stringify_keys)
    )
  rescue ActiveRecord::RecordNotUnique, ActiveRecord::RecordInvalid
    WebhookEvent.find_by!(provider: "stripe", provider_event_id: event.id)
  end

  def process!(receipt)
    object = event.data.object
    payment = find_payment(object)
    create_payment_event!(receipt, payment, object)
    return unless valid_payment_context?(receipt, payment)

    case event.type
    when "payment_intent.succeeded"
      process_success!(receipt, payment, object)
    when "checkout.session.expired"
      process_door_session_expiry!(receipt, payment, object)
    when "charge.updated"
      StripeProcessingFees.request!(payment, recheck: true) if payment
    when "payment_intent.processing"
      record_pending_provider_state!(payment, "processing")
    when "payment_intent.payment_failed"
      process_failure!(payment, object)
    when "payment_intent.canceled"
      process_cancellation!(payment)
    when "refund.created", "refund.updated", "refund.failed", "charge.refund.updated"
      process_refund_operation!(receipt, payment, object)
    when "charge.refunded"
      process_refund!(receipt, payment, object)
    when "charge.dispute.created", "charge.dispute.updated", "charge.dispute.closed"
      process_dispute!(receipt, payment, object)
    when "radar.early_fraud_warning.created", "radar.early_fraud_warning.updated"
      process_early_fraud_warning!(receipt, payment, object)
    else
      receipt.update!(status: :ignored, processed_at: Time.current)
      return
    end

    receipt.update!(status: :processed, processed_at: Time.current)
  end

  def valid_payment_context?(receipt, payment)
    return true unless payment

    incoming_mode = payload["livemode"]
    incoming_account = payload["account"].presence
    context_known = %w[test live].include?(payment.provider_environment)
    mode_matches = context_known && incoming_mode == (payment.provider_environment == "live")
    # Old local fixtures predate context snapshots. Production always requires
    # explicit mode evidence; no test event may grant production admission.
    mode_matches = true if !payment.order.online_door_card? && !Rails.env.production? && !payload.key?("livemode")
    if mode_matches && incoming_account == payment.provider_account_id
      if payload.key?("livemode") || Rails.env.production?
        begin
          StripeService.verify_payment_context!(payment)
        rescue StripeService::PaymentError
          mode_matches = false
        end
      end
      return true if mode_matches
    end

    ReconciliationException.create!(order: payment.order, payment: payment, webhook_event: receipt,
      code: "payment_context_mismatch")
    receipt.update!(status: :processed, processed_at: Time.current)
    false
  end

  def find_payment(object)
    if event.type == "checkout.session.expired"
      session_id = value(object, :id)
      return if session_id.blank?

      return Payment.find_by(provider: "stripe", stripe_checkout_session_id: session_id) || find_door_payment(object)
    end

    provider_payment_id = if event.type.start_with?("payment_intent.")
      value(object, :id)
    else
      value(object, :payment_intent)
    end
    return if provider_payment_id.blank?

    Payment.find_by(provider: "stripe", provider_payment_id: provider_payment_id) ||
      (find_door_payment(object) if event.type.start_with?("payment_intent.")) || backfill_legacy_payment(provider_payment_id)
  end

  def find_door_payment(object)
    metadata = value(object, :metadata)
    id = nested_value(metadata, :hafapass_door_payment).to_s
    return unless id.match?(/\A[1-9][0-9]{0,18}\z/)

    payment = Payment.find_by(provider: "stripe", id: id)
    payment if payment && door_metadata_matches?(payment, metadata)
  end

  def door_metadata_matches?(payment, metadata)
    order = payment.order
    order.online_door_card? && order.source == "box_office" &&
      nested_value(metadata, :hafapass_door_payment).to_s == payment.id.to_s &&
      order.checkout_key_digest.present? &&
      nested_value(metadata, :hafapass_door_checkout) == order.checkout_key_digest
  end

  def backfill_legacy_payment(provider_payment_id)
    order = Order.find_by(stripe_payment_intent_id: provider_payment_id)
    return unless order

    order.payments.create!(
      provider: "stripe",
      provider_payment_id: provider_payment_id,
      idempotency_key: "legacy:order:#{order.id}",
      amount_cents: order.total_cents,
      currency: order.currency,
      status: order.completed? ? :succeeded : :pending,
      succeeded_at: order.completed_at
    )
  rescue ActiveRecord::RecordNotUnique
    Payment.find_by(provider: "stripe", provider_payment_id: provider_payment_id)
  end

  def create_payment_event!(receipt, payment, object)
    return if receipt.payment_event

    receipt.create_payment_event!(
      payment: payment,
      event_type: event.type,
      amount_cents: value(object, :amount_received) || value(object, :amount_refunded) || value(object, :amount),
      currency: value(object, :currency)&.downcase,
      provider_created_at: receipt.provider_created_at,
      data: normalized_event_data(object)
    )
  end

  def process_success!(receipt, payment, object)
    unless payment
      ReconciliationException.create!(webhook_event: receipt, code: "payment_not_found")
      return
    end

    return process_door_success!(receipt, payment, object) if payment.order.online_door_card?

    amount = value(object, :amount_received) || value(object, :amount)
    currency = value(object, :currency)
    # This signed event proves the capture. When its amount and currency match
    # the payment exactly, a hold that lapsed only by time is fulfilled if the
    # inventory is still free (else released and refunded automatically).
    # OrderLifecycle locks the order, so a racing expiry job or a duplicate
    # event finds it completed or released and changes nothing twice.
    exact = !amount.nil? && amount.to_i == payment.amount_cents && currency.to_s.casecmp?(payment.currency)
    Commerce::OrderLifecycle.complete!(
      payment.order,
      payment: payment,
      webhook_event: receipt,
      provider_amount_cents: amount,
      provider_currency: currency,
      wallet_type: value(object, :wallet_type),
      late_completion: exact
    )
  end

  def process_door_session_expiry!(receipt, payment, object)
    return unless payment&.order&.online_door_card? && value(object, :status) == "expired"

    session_id = value(object, :id)
    return unless session_id.to_s.match?(/\Acs_#{payment.provider_environment}_[a-zA-Z0-9]+\z/)

    verified = payment.with_lock do
      if payment.stripe_checkout_session_id.nil?
        # Stripe can expire a Session before the creating request saved its
        # response. The signed metadata matches this exact local reservation.
        payment.update!(stripe_checkout_session_id: session_id)
      end
      payment.stripe_checkout_session_id == session_id
    end
    unless verified
      ReconciliationException.create!(order: payment.order, payment: payment, webhook_event: receipt, code: "payment_context_mismatch")
      return
    end

    Commerce::OrderLifecycle.expire!(payment.order, provider_expired: true)
  end

  def process_door_success!(receipt, payment, object)
    order = payment.order
    intent_id = value(object, :id)
    amount = value(object, :amount_received)
    currency = value(object, :currency)
    unless door_metadata_matches?(payment, value(object, :metadata)) && intent_id.to_s.match?(/\Api_[a-zA-Z0-9]+\z/) &&
        value(object, :status) == "succeeded" && amount == payment.amount_cents && currency == payment.currency
      ReconciliationException.create!(order: order, payment: payment, webhook_event: receipt, code: "payment_context_mismatch")
      return
    end

    Commerce::OrderLifecycle.with_order_lock!(order) do
      payment.lock!
      if payment.provider_payment_id.present? && payment.provider_payment_id != intent_id
        ReconciliationException.create!(order: order, payment: payment, webhook_event: receipt, code: "payment_context_mismatch")
        next
      end

      payment.update!(provider_payment_id: intent_id, stripe_checkout_url: nil, failure_code: nil, failure_message: nil)
      order.update!(stripe_payment_intent_id: intent_id)
      if order.pending? && !order.event.reload.published?
        Commerce::OrderLifecycle.expire!(order, provider_expired: true)
      end
      Commerce::OrderLifecycle.complete!(order, payment: payment, webhook_event: receipt,
        provider_amount_cents: amount, provider_currency: currency, late_completion: true, event_context_locked: true)
    end
  end

  def process_failure!(payment, object)
    return unless payment

    error = value(object, :last_payment_error)
    if payment.order.online_door_card? || value(object, :status) == "requires_payment_method"
      record_pending_provider_state!(payment, "requires_payment_method", error: error)
      return
    end
    Commerce::OrderLifecycle.fail!(
      payment.order,
      payment: payment,
      failure_code: nested_value(error, :code),
      failure_message: nested_value(error, :message),
      reason: "payment_failed"
    )
  end

  def record_pending_provider_state!(payment, state, error: nil)
    return unless payment

    payment.order.with_lock do
      payment.lock!
      if payment.order.pending? && payment.pending?
        previous_time = payment.provider_payload.to_h["state_created_at"]
        created_at = event.respond_to?(:created) ? event.created : nil
        return if previous_time && created_at && created_at.to_i < previous_time.to_i

        payment.update!(failure_code: nested_value(error, :code), failure_message: nested_value(error, :message),
          provider_payload: payment.provider_payload.to_h.merge("status" => state, "state_created_at" => created_at))
      end
    end
  end

  def process_cancellation!(payment)
    return unless payment && !payment.order.online_door_card?

    Commerce::OrderLifecycle.fail!(payment.order, payment: payment, reason: "payment_cancelled")
  end

  def process_refund_operation!(receipt, payment, object)
    refund = Commerce::RefundCreator.find_provider_operation(payment: payment, provider_refund: object) if payment
    if refund.nil?
      if payment
        return Commerce::ExternalRefundRecovery.ingest!(payment: payment, provider_refund: object)
      end
      ReconciliationException.create!(order: payment&.order, payment: payment, webhook_event: receipt,
        code: "refund_operation_not_found")
      return
    end
    unless payment == refund.payment && value(object, :amount).to_i == refund.amount_cents &&
        value(object, :currency).to_s.downcase == refund.currency
      record_refund_provider_issue!(receipt, refund, code: "refund_operation_mismatch", action: "unknown")
      return
    end
    if refund.succeeded? || refund.failed? || refund.cancelled?
      incoming = value(object, :status).to_s
      contradictory = (refund.succeeded? && %w[failed canceled cancelled].include?(incoming)) ||
        (!refund.succeeded? && incoming == "succeeded")
      if contradictory
        record_refund_provider_issue!(receipt, refund, code: "refund_terminal_status_conflict", action: "provider_result_conflict")
      end
      return
    end

    Commerce::RefundCreator.reconcile_refund!(refund: refund, provider_refund: object)
  rescue Commerce::RefundCreator::RefundError => e
    ReconciliationException.create!(order: payment&.order, payment: payment, webhook_event: receipt,
      code: "refund_operation_not_found", details: { error: e.message,
        provider_refund_id: value(object, :id), provider_payment_id: value(object, :payment_intent) || payment&.provider_payment_id,
        amount_cents: value(object, :amount), currency: value(object, :currency), status: value(object, :status) })
  end

  def record_refund_provider_issue!(receipt, refund, code:, action:)
    ReconciliationException.transaction do
      ReconciliationException.create!(order: refund.order, payment: refund.payment, webhook_event: receipt, code: code)
      AuditLogger.record!(action: "refund.#{action}", auditable: refund,
        organization: refund.order.event.organization, event: refund.order.event,
        source: "provider", outcome: "unknown",
        deduplication_key: "stripe:webhook:#{receipt.provider_event_id}:refund:#{refund.id}:#{action}:#{code}",
        metadata: { order_id: refund.order_id, payment_id: refund.payment_id,
          amount_cents: refund.amount_cents, code: code })
    end
  end

  def process_refund!(receipt, payment, object)
    unless payment
      ReconciliationException.create!(webhook_event: receipt, code: "refunded_payment_not_found")
      return
    end

    provider_refunds = Array(nested_value(value(object, :refunds), :data))
    # Modern charge snapshots need not embed refund operations. Their aggregate
    # cannot identify or verify an operation, and may predate later refunds.
    # The subscribed refund.created/updated events carry the durable identities.
    if provider_refunds.empty?
      if value(object, :amount_refunded).to_i > payment.refunds.succeeded.sum(:amount_cents)
        record_aggregate_gap!(receipt, payment, object)
      end
      return
    end

    provider_refunds.each do |entry|
      next unless value(entry, :amount).present?

      process_refund_operation!(receipt, payment, entry)
    end
    provider_total = value(object, :amount_refunded).to_i
    succeeded_total = payment.refunds.succeeded.sum(:amount_cents)
    # A recent/truncated page may omit returned money. Neither a pending
    # reservation nor a failed operation covers an unbooked aggregate.
    if provider_refunds.any? { |entry| value(entry, :status).to_s != "succeeded" }
      record_aggregate_gap!(receipt, payment, object) if provider_total > succeeded_total
      return
    end
    if payment.order.order_items.empty?
      ReconciliationException.create!(
        order: payment.order,
        payment: payment,
        webhook_event: receipt,
        code: "refund_missing_order_item_ledger",
        actual_amount_cents: provider_total
      )
      return
    end
    if provider_total < succeeded_total
      # Charge events carry a point-in-time aggregate. A delayed snapshot of
      # already-booked operations must not undo or quarantine newer refunds.
      return if recorded_refund_snapshot?(payment, provider_refunds, provider_total)

      ReconciliationException.create!(
        order: payment.order,
        payment: payment,
        webhook_event: receipt,
        code: "provider_refund_total_decreased",
        expected_amount_cents: succeeded_total,
        actual_amount_cents: provider_total
      )
      return
    end
    return if provider_total == succeeded_total

    record_aggregate_gap!(receipt, payment, object)
  rescue Commerce::RefundCreator::RefundError => e
    ReconciliationException.create!(order: payment.order, payment: payment, webhook_event: receipt,
      code: "refund_operation_not_found", details: { error: e.message })
  end

  def record_aggregate_gap!(receipt, payment, object)
    ReconciliationException.find_or_create_by!(order: payment.order, payment: payment,
      webhook_event: receipt, code: "refund_aggregate_requires_reconciliation") do |issue|
      issue.actual_amount_cents = value(object, :amount_refunded).to_i
    end
  end

  def recorded_refund_snapshot?(payment, provider_refunds, provider_total)
    return false if provider_refunds.empty?

    ids = provider_refunds.map { |entry| value(entry, :id) }
    return false if ids.any?(&:blank?) || ids.uniq.length != ids.length

    booked_total = 0
    matches = provider_refunds.all? do |entry|
      refund = payment.refunds.succeeded.find_by(provider: "stripe", provider_refund_id: value(entry, :id))
      next false unless refund && value(entry, :status) == "succeeded"
      next false if value(entry, :amount).present? && value(entry, :amount).to_i != refund.amount_cents
      next false if value(entry, :currency).present? && value(entry, :currency).to_s.downcase != refund.currency

      booked_total += refund.amount_cents
      true
    end
    matches && booked_total == provider_total
  end

  def process_dispute!(receipt, payment, object)
    unless payment
      ReconciliationException.create!(webhook_event: receipt, code: "disputed_payment_not_found")
      return
    end

    Dispute.transaction do
      payment.order.event.organization.lock!("FOR NO KEY UPDATE")
      payment.order.event.lock!
      payment.order.lock!
      provider_id = value(object, :id)
      dispute = Dispute.find_or_initialize_by(provider: "stripe", provider_dispute_id: provider_id)
      new_dispute = dispute.new_record?
      before_data = dispute.attributes.slice("status", "reason", "closed_at") unless new_dispute
      provider_status = value(object, :status).to_s
      if dispute.persisted? && (dispute.won? || dispute.lost?)
        apply_dispute_loss_to_sale!(dispute) if dispute.lost? && !dispute.loss_reversed_at
        if dispute.lost? && late_win?(provider_status)
          reverse_dispute_loss!(receipt, payment, dispute, provider_status)
        elsif dispute.won? && provider_status == "lost"
          record_loss_receipt_after_win!(receipt, payment, dispute)
        elsif dispute.lost?
          # A redelivered or stale loss notice: the loss posts once.
          Commerce::BuyerReturnPostings.record_dispute_loss!(dispute)
        end
        Commerce::NeverFulfilledResolution.evaluate_payment!(payment.id, trigger: "dispute_#{provider_status}")
        next
      end

      status = if event.type == "charge.dispute.closed"
        case provider_status
        when "won", "warning_closed" then :won
        when "lost" then :lost
        else :open
        end
      else
        :open
      end
      if dispute.new_record?
        dispute.assign_attributes(
          order: payment.order,
          payment: payment,
          amount_cents: value(object, :amount).to_i,
          currency: value(object, :currency).to_s.downcase.presence || payment.currency,
          opened_at: receipt.provider_created_at || Time.current
        )
      end
      dispute.assign_attributes(
        reason: value(object, :reason),
        status: status,
        closed_at: status == :open ? nil : Time.current,
        provider_payload: { status: provider_status }.compact
      )
      dispute.save!
      StripeProcessingFees.require_adjustment_review!(payment, reference: "dispute:#{provider_id}:#{provider_status}") if status != :open
      Commerce::BuyerReturnPostings.record_dispute_loss!(dispute) if dispute.lost?
      apply_dispute_loss_to_sale!(dispute) if dispute.lost?
      action = if status == :open
        event.type == "charge.dispute.created" ? "dispute.opened" : "dispute.updated"
      else
        "dispute.#{status}"
      end
      AuditLogger.record!(action: action, auditable: dispute,
        organization: payment.order.event.organization, event: payment.order.event,
        source: "provider", outcome: "succeeded",
        deduplication_key: "stripe:webhook:#{receipt.provider_event_id}:#{action}",
        before_data: before_data || {}, after_data: dispute.attributes.slice("status", "reason", "closed_at"),
        metadata: { order_id: payment.order_id, payment_id: payment.id,
          amount_cents: dispute.amount_cents, currency: dispute.currency,
          provider_status: provider_status })
      Commerce::NeverFulfilledResolution.evaluate_payment!(payment.id, trigger: "dispute_#{status}")
    end
  end

  # A card issuer reported likely fraud. Nothing changes automatically: an
  # administrator reviews the open exception and can cancel the tickets and
  # refund as fraudulent (Commerce::EarlyFraudWarningRefund). The code is not
  # a RefundSafety financial code, so it never blocks that refund.
  def process_early_fraud_warning!(receipt, payment, object)
    warning_id = value(object, :id).to_s
    charge = value(object, :charge)
    details = { "warning_id" => warning_id, "fraud_type" => value(object, :fraud_type),
      "actionable" => value(object, :actionable), "charge_id" => charge.is_a?(String) ? charge : nested_value(charge, :id),
      "payment_intent_id" => value(object, :payment_intent).presence&.to_s, "last_event_type" => event.type }.compact
    existing = existing_early_fraud_warning(warning_id)
    if existing
      existing.update!(details: existing.details.merge(details))
      return
    end

    # A unique index on the warning ID settles the created/updated race: the
    # losing insert rolls back to its savepoint and updates the winner.
    issue = begin
      ReconciliationException.transaction(requires_new: true) do
        ReconciliationException.create!(order: payment&.order, payment: payment, webhook_event: receipt,
          code: "early_fraud_warning", details: details)
      end
    rescue ActiveRecord::RecordNotUnique
      winner = existing_early_fraud_warning(warning_id)
      raise unless winner

      winner.with_lock { winner.update!(details: winner.details.merge(details)) }
      return
    end
    Sentry.capture_message("Stripe early fraud warning received; review the order", level: :warning,
      fingerprint: ["stripe-early-fraud-warning"],
      extra: { reconciliation_exception_id: issue.id, order_id: payment&.order_id, payment_id: payment&.id,
        fraud_type: details["fraud_type"], payment_found: payment.present? })
  end

  def existing_early_fraud_warning(warning_id)
    return if warning_id.blank?

    ReconciliationException.where(code: "early_fraud_warning").where("details ->> 'warning_id' = ?", warning_id).order(:id).first
  end

  # Stripe can return disputed funds after a loss (a late win). Only a signed
  # closed or updated notice whose dispute object says won (or
  # warning_closed) reverses a recorded loss (design §5.6).
  def late_win?(provider_status)
    # process_dispute! receives only the dispute created, updated and closed events.
    !event.type.end_with?(".created") && %w[won warning_closed].include?(provider_status)
  end

  # The loss stays recorded (status lost, closed_at unchanged, so the loss
  # month is unchanged). The database stamps loss_reversed_at once; a
  # duplicate or stale win changes nothing. A classified payment posts the
  # recomputed signed delta; a fulfilled sale opens dispute_late_win for
  # finance (the organizer-side credit is a follow-up, design §11).
  def reverse_dispute_loss!(receipt, payment, dispute, provider_status)
    if dispute.loss_reversed_at.nil?
      dispute.update!(loss_reversed_at: Time.current)
      dispute.reload
      AuditLogger.record!(action: "dispute.loss_reversed", auditable: dispute,
        organization: payment.order.event.organization, event: payment.order.event,
        source: "provider", outcome: "succeeded",
        deduplication_key: "dispute:#{dispute.id}:loss_reversed",
        before_data: { status: "lost" }, after_data: dispute.attributes.slice("status", "closed_at", "loss_reversed_at"),
        metadata: { order_id: payment.order_id, payment_id: payment.id, amount_cents: dispute.amount_cents,
          currency: dispute.currency, provider_status: provider_status, webhook_event_id: receipt.id })
      StripeProcessingFees.require_adjustment_review!(payment, reference: "dispute:#{dispute.provider_dispute_id}:loss_reversed")
    end
    if UnfulfilledCapture.exists?(payment_id: payment.id)
      Commerce::BuyerReturnPostings.record_loss_reversal!(dispute)
    else
      ReconciliationException.where(payment: payment, code: "dispute_late_win").where("details ->> 'dispute_id' = ?", dispute.id.to_s)
        .first || ReconciliationException.create!(order: payment.order, payment: payment, webhook_event: receipt,
          code: "dispute_late_win", actual_amount_cents: dispute.amount_cents,
          details: { dispute_id: dispute.id, provider_dispute_id: dispute.provider_dispute_id })
    end
  end

  # A loss notice that arrives after the dispute was already recorded as won
  # (reordered delivery of a late win). Net, no money stayed with the buyer, so
  # nothing posts and the status is not rewritten; the receipt and this audit
  # keep the evidence for finance and the A2 readers.
  def record_loss_receipt_after_win!(receipt, payment, dispute)
    AuditLogger.record!(action: "dispute.loss_receipt_after_win", auditable: dispute,
      organization: payment.order.event.organization, event: payment.order.event,
      source: "provider", outcome: "succeeded",
      deduplication_key: "stripe:webhook:#{receipt.provider_event_id}:dispute.loss_receipt_after_win",
      metadata: { order_id: payment.order_id, payment_id: payment.id, amount_cents: dispute.amount_cents,
        webhook_event_id: receipt.id, provider_created_at: receipt.provider_created_at&.utc&.iso8601 })
  end

  # A lost dispute cancels the order's tickets only when its payment owns the
  # sale (A1-R1 review finding 1). One on a payment-scope never-fulfilled
  # capture never touches the sale. One on a payment whose ownership is not
  # proven (a second payment before classification, a legacy order without
  # completion evidence) is recorded and held for ownership evidence. The
  # database refuses the cancellation for every writer, old or new.
  def apply_dispute_loss_to_sale!(dispute)
    return if UnfulfilledCapture.isolated_payment?(dispute.payment_id)

    if Commerce::SaleEffectHold.owner?(dispute.payment_id)
      Commerce::SaleEffectHold.cancel_disputed_tickets!(dispute.order, dispute)
    else
      Commerce::SaleEffectHold.hold!(dispute,
        reason: dispute.order.fulfilled_by_payment_id ? "not_fulfilling_payment" : "ownership_unproven")
    end
  end

  def normalized_event_data(object)
    {
      provider_object_id: value(object, :id),
      payment_intent_id: value(object, :payment_intent),
      status: value(object, :status)
    }.compact
  end

  def value(object, key)
    return object.public_send(key) if object.respond_to?(key)
    return object[key] if object.respond_to?(:key?) && object.key?(key)
    object[key.to_s] if object.respond_to?(:key?) && object.key?(key.to_s)
  end

  def nested_value(object, key)
    object ? value(object, key) : nil
  end
end
