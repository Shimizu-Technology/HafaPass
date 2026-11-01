# frozen_string_literal: true

# Platform-admin review of every ReconciliationException code.
#
# Any open exception linked to an order (directly or through its payment)
# blocks finalizing that event's statement (Settlements::Finalizer) and every
# payout for the whole organization (OrganizationPayoutBalance). The list and
# detail show that blast radius so the operator knows what each row holds up.
class Api::V1::Admin::ReconciliationExceptionsController < Api::V1::Admin::BaseController
  include AdminListing

  STATUSES = %w[open resolved all].freeze
  NOTE_LIMIT = 2000
  DETAIL_VALUE_LIMIT = 300
  INCLUDES = [{ order: { event: :organization } }, { payment: [:refunds, { order: { event: :organization } }] }].freeze

  # Codes where a note alone could close a record while money is still
  # unaccounted for. Each needs an explicit confirmation flag (sent as
  # `<flag>: true`) and an evidence note, audited as its own action.
  #
  # verified_no_ledger_change: external Stripe refunds normally go through
  # Refund issues -> Verify (Commerce::ExternalRefundRecovery), which records
  # the refund. Resolving instead says nothing needed recording.
  # reviewed_no_action: an early fraud warning normally gets the fraud refund
  # (Admin -> Orders); resolving instead records the decision not to refund.
  CONFIRMATIONS = {
    "verified_no_ledger_change" => {
      audit_action: "reconciliation_exception.resolved_without_ledger_change",
      label: "I checked Stripe and no HåfaPass refund or payment record needs to change."
    },
    "reviewed_no_action" => {
      audit_action: "reconciliation_exception.reviewed_no_action",
      label: "I reviewed the order and decided not to refund it."
    }
  }.freeze
  CONFIRMATION_BY_CODE = (Commerce::ExternalRefundRecovery::RECOVERABLE_CODES.index_with { "verified_no_ledger_change" })
    .merge("card_present_result_unknown" => "verified_no_ledger_change",
      Commerce::EarlyFraudWarningRefund::CODE => "reviewed_no_action").freeze
  EVIDENCE_NOTE_MINIMUM = 20

  before_action -> { response.headers["Cache-Control"] = "no-store" }
  before_action :set_issue, only: [:show, :resolve, :refund_buyer]

  # GET /api/v1/admin/reconciliation_exceptions
  # Filters: status (open, resolved or all; default open), code,
  # organization_id, event_id, q (order number, code or provider ID).
  def index
    status = STATUSES.include?(params[:status].to_s) ? params[:status].to_s : "open"
    scope = linked_scope
    scope = scope.where(status: status) unless status == "all"
    scope = scope.where(code: params[:code].to_s) if params[:code].present?
    scope = scope.where("events.organization_id = ?", params[:organization_id].to_i) if params[:organization_id].present?
    scope = scope.where("events.id = ?", params[:event_id].to_i) if params[:event_id].present?
    if (term = search_term)
      order_id = term.delete_prefix("#")
      scope = scope.where("reconciliation_exceptions.code ILIKE :q OR payments.provider_payment_id ILIKE :q" \
        "#{order_id.match?(/\A\d{1,18}\z/) ? ' OR orders.id = :id' : ''}", q: like_pattern(term), id: order_id.to_i)
    end
    issues, meta = admin_page(scope.includes(*INCLUDES)
      .order("reconciliation_exceptions.created_at DESC, reconciliation_exceptions.id DESC"))
    open = ReconciliationException.open
    render json: {
      reconciliation_exceptions: issues.map { |issue| issue_json(issue) },
      meta: meta,
      status_counts: { open: open.count, resolved: ReconciliationException.resolved.count },
      open_code_counts: open.group(:code).order(:code).count,
      payout_blocks: payout_blocks
    }
  end

  # GET /api/v1/admin/reconciliation_exceptions/:id
  def show
    render json: { reconciliation_exception: issue_json(@issue, detail: true) }
  end

  # POST /api/v1/admin/reconciliation_exceptions/:id/resolve
  # Body: note (required); for codes in CONFIRMATION_BY_CODE also the
  # confirmation flag (e.g. verified_no_ledger_change: true). Records the
  # review note in the audit log. Refused while a late capture still owes the
  # buyer money: that is returned by Refund buyer, which resolves it.
  def resolve
    note = params[:note].to_s.strip
    return render json: { error: "Add a note explaining how this was reconciled." }, status: :unprocessable_content if note.blank?
    if note.length > NOTE_LIMIT
      return render json: { error: "Keep the note under #{NOTE_LIMIT} characters." }, status: :unprocessable_content
    end

    ReconciliationException.transaction do
      @issue.lock!
      unless @issue.open?
        return render json: { error: "This exception is already resolved.",
          reconciliation_exception: issue_json(@issue, detail: true) }, status: :conflict
      end

      rule = resolution_rule(@issue)
      if rule[:blocked]
        return render json: { error: rule[:blocked], reconciliation_exception: issue_json(@issue, detail: true) },
          status: :unprocessable_content
      end
      flag = rule[:confirmation]
      if flag && !confirmed?(flag)
        return render json: { error: "Confirm \"#{CONFIRMATIONS.dig(flag, :label)}\" to resolve this without " \
          "#{flag == 'reviewed_no_action' ? 'the fraud refund' : 'recording a refund'}.", confirmation_required: flag },
          status: :unprocessable_content
      end
      if flag && note.length < EVIDENCE_NOTE_MINIMUM
        return render json: { error: "Describe the evidence you checked (at least #{EVIDENCE_NOTE_MINIMUM} characters)." },
          status: :unprocessable_content
      end

      action = flag ? CONFIRMATIONS.dig(flag, :audit_action) : "reconciliation_exception.manually_resolved"
      metadata = { code: @issue.code, order_id: issue_order&.id, payment_id: @issue.payment_id, note: note }
      metadata[flag] = true if flag
      @issue.resolve!
      AuditLogger.record!(action: action, auditable: @issue,
        actor: @current_user, organization: issue_event&.organization, event: issue_event,
        before_data: { status: "open" }, after_data: { status: "resolved" }, metadata: metadata,
        request: request, deduplication_key: "reconciliation_exception:#{@issue.id}:#{action.split('.').last}")
    end
    render json: { reconciliation_exception: issue_json(@issue.reload, detail: true) }
  end

  # POST /api/v1/admin/reconciliation_exceptions/:id/refund_buyer
  # Late captures only: refunds the payment through Commerce::LateCaptureRefund
  # (the same idempotency key as the automatic LateCaptureRefundJob). The
  # audit entry is written after the provider call, with its outcome.
  def refund_buyer
    unless late_capture_refundable?(@issue)
      return render json: { error: "Only an open late-capture exception on a Stripe test or live payment can be refunded here." },
        status: :unprocessable_content
    end
    if (problem = late_capture_refund_blocker(@issue))
      return render json: { error: problem }, status: :unprocessable_content
    end

    amount_cents = late_capture_owed_cents(@issue)
    refund = nil
    begin
      refund = Commerce::LateCaptureRefund.call(payment: @issue.payment, requested_by: @current_user)
    rescue Commerce::LateCaptureRefund::NotApplicable, Commerce::RefundCreator::RefundError,
      StripeService::PaymentError, Stripe::StripeError => e
      @issue.payment.refunds.reset # the service may have recorded a failed refund
      record_buyer_refund!(amount_cents: amount_cents, refund: late_capture_refund(@issue), error: e)
      return render json: { error: e.message }, status: :unprocessable_content
    end

    record_buyer_refund!(amount_cents: amount_cents, refund: refund)
    render json: {
      refund: { id: refund.id, status: refund.status, amount_cents: refund.amount_cents, currency: refund.currency },
      reconciliation_exception: issue_json(@issue.reload, detail: true)
    }, status: :created
  end

  private

  # Each exception's order is its own order or its payment's order; the
  # payout and finalization checks use the same two links.
  def linked_scope
    ReconciliationException
      .joins("LEFT JOIN payments ON payments.id = reconciliation_exceptions.payment_id")
      .joins("LEFT JOIN orders ON orders.id = COALESCE(reconciliation_exceptions.order_id, payments.order_id)")
      .joins("LEFT JOIN events ON events.id = orders.event_id")
  end

  # Every organization whose payouts are frozen by open exceptions, with the
  # events whose statements cannot be finalized.
  def payout_blocks
    counts = linked_scope.merge(ReconciliationException.open).where.not(events: { id: nil })
      .group("events.organization_id", "events.id").count
    events = Event.where(id: counts.keys.map(&:last)).includes(:organization).index_by(&:id)
    blocked = counts.group_by { |(organization_id, _), _| organization_id }.map do |organization_id, rows|
      organization = events.fetch(rows.first.first.last).organization
      {
        organization: { id: organization_id, name: organization.name },
        open_count: rows.sum(&:last),
        events: rows.map { |(_, event_id), count|
          event = events.fetch(event_id)
          { id: event.id, title: event.title, status: event.status, open_count: count }
        }.sort_by { |event| [-event[:open_count], event[:id]] }
      }
    end
    {
      organizations: blocked.sort_by { |entry| [-entry[:open_count], entry[:organization][:id]] },
      unlinked_open_count: linked_scope.merge(ReconciliationException.open).where(events: { id: nil }).count
    }
  end

  def set_issue
    @issue = ReconciliationException.includes(*INCLUDES).find_by(id: params[:id])
    render json: { error: "Reconciliation exception not found" }, status: :not_found unless @issue
  end

  def issue_order(issue = @issue)
    issue.order || issue.payment&.order
  end

  def issue_event(issue = @issue)
    issue_order(issue)&.event
  end

  def late_capture_refundable?(issue)
    issue.open? && Commerce::LateCaptureRefund::CODES.include?(issue.code) && issue.payment.present? &&
      issue.payment.provider == "stripe" && %w[test live].include?(issue.payment.provider_environment)
  end

  def late_capture_owed_cents(issue)
    returned = issue.payment.refunds.select { |refund| refund.pending? || refund.succeeded? }.sum(&:amount_cents)
    [issue.payment.amount_cents - returned, 0].max
  end

  # Uses the preloaded payment refunds (reloaded by lock! in #resolve).
  def late_capture_refund(issue)
    key = Commerce::LateCaptureRefund.idempotency_key(issue.payment)
    issue.payment.refunds.find { |refund| refund.idempotency_key == key }
  end

  # Why Refund buyer cannot run now, or nil.
  def late_capture_refund_blocker(issue)
    earlier = late_capture_refund(issue)
    if earlier&.failed? || earlier&.cancelled?
      return "The automatic refund failed. Use Retry refund on its row in Refund issues."
    end
    return "A refund for this payment is already #{earlier.status}." if earlier&.pending? || earlier&.succeeded?
    return "A refund for this payment is still pending. Wait for it to finish." if issue.payment.refunds.any?(&:pending?)
    return "Nothing is owed to the buyer for this payment." unless late_capture_owed_cents(issue).positive?

    nil
  end

  def record_buyer_refund!(amount_cents:, refund:, error: nil)
    # The refund record is the source of truth; an error with no refund, or a
    # failed one, is a failure, and a pending refund after an error is unknown.
    outcome = if refund.nil? || refund.failed? || refund.cancelled? then "failed"
    elsif refund.succeeded? then "succeeded"
    elsif error || refund.failure_code == "provider_result_unknown" then "unknown"
    else "requested"
    end
    metadata = { code: @issue.code, order_id: issue_order.id, payment_id: @issue.payment_id, amount_cents: amount_cents,
      refund_id: refund&.id, refund_status: refund&.status }
    metadata.merge!(error_class: error.class.name, error: error.message.to_s.first(DETAIL_VALUE_LIMIT)) if error
    AuditLogger.record!(action: "reconciliation_exception.buyer_refund_requested", auditable: @issue,
      actor: @current_user, organization: issue_event.organization, event: issue_event, outcome: outcome,
      metadata: metadata, request: request)
  end

  # What a note-only resolution needs: {} (allowed), { confirmation: flag }
  # (allowed with that flag and an evidence note) or { blocked: message }.
  def resolution_rule(issue)
    if Commerce::LateCaptureRefund::CODES.include?(issue.code) && issue.payment
      if issue.payment.refunds.any?(&:pending?)
        return { blocked: "A refund for this payment is still pending. It resolves this exception when it succeeds." }
      end
      return {} unless late_capture_owed_cents(issue).positive?
      # Payments HåfaPass cannot refund itself (simulated or legacy) can only
      # have been returned outside HåfaPass.
      return { confirmation: "verified_no_ledger_change" } unless late_capture_refundable?(issue)

      owed = late_capture_owed_cents(issue)
      earlier = late_capture_refund(issue)
      next_step = earlier&.failed? || earlier&.cancelled? ? "The automatic refund failed: use Retry refund on its row in Refund issues." :
        "Use Refund buyer; the exception resolves when the refund succeeds."
      return { blocked: "The buyer is still owed #{format('$%<dollars>d.%<cents>02d', dollars: owed / 100, cents: owed % 100)}. #{next_step}" }
    end

    flag = CONFIRMATION_BY_CODE[issue.code]
    flag ? { confirmation: flag } : {}
  end

  def confirmed?(flag)
    [true, "true"].include?(params[flag])
  end

  def available_actions(issue, order)
    return [] unless issue.open?

    actions = []
    actions << "refund_buyer" if late_capture_refundable?(issue) && late_capture_refund_blocker(issue).nil?
    actions << "fraud_refund" if issue.code == Commerce::EarlyFraudWarningRefund::CODE && order
    actions << "verify_external_refund" if Commerce::ExternalRefundRecovery::RECOVERABLE_CODES.include?(issue.code) && order
    actions << "resolve" unless resolution_rule(issue)[:blocked]
    actions
  end

  def issue_json(issue, detail: false)
    order = issue_order(issue)
    event = order&.event
    payment = issue.payment
    json = {
      id: issue.id, code: issue.code, status: issue.status, created_at: issue.created_at, resolved_at: issue.resolved_at,
      expected_amount_cents: issue.expected_amount_cents, expected_currency: issue.expected_currency,
      actual_amount_cents: issue.actual_amount_cents, actual_currency: issue.actual_currency,
      webhook_event_id: issue.webhook_event_id,
      order: order && { id: order.id, reference: order.reference, buyer_name: order.buyer_name, buyer_email: order.buyer_email,
        status: order.status, total_cents: order.total_cents, currency: order.currency },
      payment: payment && { id: payment.id, provider: payment.provider, provider_environment: payment.provider_environment,
        provider_payment_id: payment.provider_payment_id, amount_cents: payment.amount_cents, currency: payment.currency,
        status: payment.status },
      event: event && { id: event.id, title: event.title, status: event.status },
      organization: event && { id: event.organization_id, name: event.organization.name },
      # Open and linked to an order: blocks this event's statement and all of
      # the organization's payouts until resolved.
      blocks_payouts: issue.open? && event.present?,
      actions: available_actions(issue, order)
    }
    if issue.open?
      rule = resolution_rule(issue)
      json[:resolve_blocked_reason] = rule[:blocked]
      json[:resolve_confirmation] = rule[:confirmation] &&
        { flag: rule[:confirmation], label: CONFIRMATIONS.dig(rule[:confirmation], :label), evidence_note_minimum: EVIDENCE_NOTE_MINIMUM }
    end
    json[:late_capture_owed_cents] = late_capture_owed_cents(issue) if payment && Commerce::LateCaptureRefund::CODES.include?(issue.code)
    return json unless detail

    json.merge(details: safe_details(issue.details), history: history(issue))
  end

  # Admin-only. Scalars only, bounded, so a provider payload cannot be echoed whole.
  def safe_details(details)
    details.to_h.each_with_object({}) do |(key, value), result|
      next unless value.nil? || value.is_a?(String) || value.is_a?(Numeric) || value == true || value == false

      result[key.to_s] = value.is_a?(String) ? value.first(DETAIL_VALUE_LIMIT) : value
    end
  end

  def history(issue)
    AuditLog.where(auditable: issue).includes(:actor_user).order(:occurred_at, :id).map do |log|
      { id: log.id, action: log.action, occurred_at: log.occurred_at, source: log.source, outcome: log.outcome,
        actor: user_summary(log.actor_user), note: log.metadata["note"], refund_id: log.metadata["refund_id"] }
    end
  end
end
