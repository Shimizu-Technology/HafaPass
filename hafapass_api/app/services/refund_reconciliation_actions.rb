# frozen_string_literal: true

class RefundReconciliationActions
  class ActionError < StandardError; end
  class Forbidden < ActionError; end

  TYPES = { "refund" => Refund, "cancellation" => EventCancellationRefundItem,
    "request" => EventChangeResponse, "dispute" => Dispute }.freeze

  def self.call(**options)
    new(**options).call
  end

  def initialize(type:, id:, action:, actor:, params: {}, request: nil, system: false, stripe_call_budget: nil)
    @type = type.to_s
    @record = TYPES.fetch(@type) { raise ActionError, "Refund item not found" }.find(id)
    @action = action.to_s
    @actor = actor
    @params = params.to_h.stringify_keys
    @request = request
    @system = system
    @stripe_call_budget = stripe_call_budget
  end

  def call
    authorize!
    audit!("refund_reconciliation.action_attempted", @record, { operation: @action })
    case @action
    when "retry" then retry_refund!
    when "resync" then resync_refund!
    when "manual_return" then record_manual_return!
    when "unable" then mark_unable!
    else raise ActionError, "Unknown refund action"
    end
  rescue StripeService::AmbiguousRefund => e
    raise if @system

    audit!("refund_reconciliation.unable", @record, { reason: e.message }) if @type == "refund"
    raise ActionError, e.message
  rescue Stripe::RateLimitError, StripeService::BudgetExceeded => e
    raise if @system

    raise ActionError, e.message
  rescue Commerce::RefundCreator::RefundError, StripeService::PaymentError, Stripe::StripeError => e
    raise ActionError, e.message
  end

  private

  def order
    @record.order
  end

  def event
    order.event
  end

  def authorize!
    return if @system && @action == "resync" && @type == "refund"

    raise Forbidden, "Sign in to manage refunds" unless @actor&.persisted?
    return if @actor.admin?

    unless %w[manual_return retry].include?(@action) && @type == "cancellation" &&
        OrganizationAuthorization.allowed?(user: @actor, organization: event.organization, permission: :refund, event: event)
      raise Forbidden, "You do not have permission to perform this action"
    end
  end

  def retry_refund!
    if @type == "request"
      return execute_buyer_request!
    end
    if @type == "cancellation"
      return retry_cancellation_item!
    end
    raise ActionError, "Only a failed or cancelled Stripe refund can be retried" unless
      @type == "refund" && (@record.failed? || @record.cancelled?) && @record.provider == "stripe"
    raise ActionError, "Resolve the unknown provider result before retrying" if @record.failure_code == "provider_result_unknown"

    provider = find_provider_refund(@record)
    if provider && provider.status.to_s != "failed" && !%w[canceled cancelled].include?(provider.status.to_s)
      Commerce::RefundCreator.reconcile_refund!(refund: @record, provider_refund: provider)
      raise ActionError, "Stripe has not confirmed this refund failed; review its provider status"
    end
    raise ActionError, "Another refund is pending for this order" if order.refunds.pending.exists?
    amount = [@record.amount_cents, order.refundable_cents].min
    raise ActionError, "The buyer balance is already resolved" unless amount.positive?

    result = Commerce::RefundCreator.call(order: order, payment: @record.payment, amount_cents: amount,
      reason: @record.reason.presence || "refund_reconciliation_retry", requested_by: @actor,
      idempotency_key: "refund-reconciliation/#{@record.id}")
    audit!("refund_reconciliation.retry", @record, { retry_refund_id: result.id, amount_cents: amount })
    result
  end

  def retry_cancellation_item!
    item = @record
    raise ActionError, "Only a failed cancellation refund can be retried" unless item.failed?

    original = order.refunds.find_by(idempotency_key: item.refund_key)
    if original&.failure_code == "provider_result_unknown"
      raise ActionError, "Resolve the unknown Stripe result before retrying"
    end
    if original&.provider_refund_id.present?
      provider = find_provider_refund(original)
      unless provider && %w[failed canceled cancelled].include?(provider.status.to_s)
        raise ActionError, "Stripe has not confirmed the prior refund failed"
      end
    end
    raise ActionError, "Another refund is pending for this order" if order.refunds.pending.exists?

    item.with_lock do
      raise ActionError, "This cancellation item is no longer failed" unless item.failed?

      item.update!(status: :pending, retry_generation: item.retry_generation + (original ? 1 : 0), last_error: nil)
    end
    item.event_cancellation_refund_run.update!(status: :processing, completed_at: nil)
    EventCancellationRefundJob.perform_later(item.event_cancellation_refund_run_id)
    audit!("refund_reconciliation.cancellation_retry", item, { order_id: order.id })
    item
  end

  def execute_buyer_request!
    raise ActionError, "Only an unexecuted buyer request can be issued" unless @record.decision == "refund_requested"
    raise ActionError, "The buyer request already has a refund" if order.refunds.exists?(reason: "event_change_refund")

    tickets = order.tickets.where(status: :issued).to_a.select { |ticket| ticket.refundable_cents.positive? }
    raise ActionError, "The buyer balance is already resolved" if tickets.empty?

    result = Commerce::RefundCreator.call(order: order, tickets: tickets, reason: "event_change_refund",
      requested_by: @actor, idempotency_key: "event-change-reconciliation/#{@record.id}")
    audit!("refund_reconciliation.request_executed", @record, { refund_id: result.id })
    result
  end

  def resync_refund!
    raise ActionError, "Only a pending Stripe refund can be checked" unless @type == "refund" && @record.pending? && @record.provider == "stripe"

    provider = find_provider_refund(@record)
    raise ActionError, "Stripe has no matching refund yet; keep this item open for review" unless provider
    if @record.provider_refund_id.present? && provider.id != @record.provider_refund_id
      raise ActionError, "Stripe returned a different refund; finance review is required"
    end
    result = Commerce::RefundCreator.reconcile_refund!(refund: @record, provider_refund: provider)
    audit!("refund_reconciliation.resynced", @record, { provider_refund_id: provider.id, provider_status: provider.status })
    result
  end

  def find_provider_refund(refund)
    if refund.provider_refund_id.present?
      StripeService.retrieve_refund(refund.provider_refund_id, payment: refund.payment,
        call_budget: @stripe_call_budget)
    else
      StripeService.find_refund(refund.payment.provider_payment_id,
        idempotency_key: refund.idempotency_key, payment: refund.payment,
        expected_amount_cents: refund.amount_cents, expected_created_at: refund.created_at,
        call_budget: @stripe_call_budget)
    end
  end

  def record_manual_return!
    raise ActionError, "Only a manual cancellation return can be recorded" unless @type == "cancellation" && @record.needs_manual?
    reference = @params["reference"].to_s.strip
    note = @params["note"].to_s.strip
    returned_at = @params["returned_at"].to_s
    raise ActionError, "Reference, return date, and note are required" if reference.blank? || returned_at.blank? || note.blank?
    raise ActionError, "Reference or note is too long" if reference.length > 255 || note.length > 2000

    item = @record
    result = nil
    event.organization.with_lock do
      order.with_lock do
        item.with_lock do
          raise ActionError, "This return has already been resolved" unless item.needs_manual?
          payments = order.payments.where(status: [:succeeded, :partially_refunded])
          payments = payments.merge(Payment.live_or_legacy_capture) if Rails.env.production?
          payment = payments.order(:id).first
          amount = EventCancellationRefunds.balance_cents(order)
          raise ActionError, "The buyer balance is already resolved" unless amount.positive?

          kind = if order.payment_method == "door_cash" && payment&.provider == "door_cash"
            :cash_return
          elsif order.payment_method == "door_card" && payment && !%w[stripe door_cash].include?(payment.provider)
            :manual_card_return
          end
          raise ActionError, "This payment does not support manual return recording" unless kind
          raise Forbidden, "Only an administrator can record non-Stripe card returns" if kind == :manual_card_return && !@actor.admin?

          result = Commerce::RefundCreator.call(order: order, payment: payment, amount_cents: amount,
            reason: kind == :cash_return ? "event_cancelled_cash_return" : "event_cancelled_manual_card_return",
            requested_by: @actor, idempotency_key: item.refund_key,
            kind => { reference: reference, returned_at: returned_at })
          item.update!(status: :refunded, amount_cents: amount, last_error: nil) if result.succeeded?
          audit!("refund_reconciliation.manual_return", item,
            { order_id: order.id, refund_id: result.id, amount_cents: amount, reference: reference,
              note: note, method: kind == :cash_return ? "cash" : "card" })
        end
      end
    end
    item.event_cancellation_refund_run.reconcile_status!
    EventCancellationRefundJob.perform_later(item.event_cancellation_refund_run_id)
    result
  end

  def mark_unable!
    reason = @params["reason"].to_s.strip
    raise ActionError, "A reason is required" if reason.blank?
    raise ActionError, "Reason is too long" if reason.length > 2000
    unless RefundReconciliationQueue.new(event_id: event.id).entries.any? { |entry| entry[:type] == @type && entry[:id] == @record.id }
      raise ActionError, "This refund item is already resolved"
    end

    audit!("refund_reconciliation.unable", @record, { reason: reason })
    @record
  end

  def audit!(action, auditable, metadata)
    AuditLogger.record!(action: action, auditable: auditable, actor: @actor,
      organization: event.organization, metadata: metadata, request: @request)
  end
end
