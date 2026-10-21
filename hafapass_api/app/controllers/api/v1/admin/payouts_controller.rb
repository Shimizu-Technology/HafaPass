# frozen_string_literal: true

class Api::V1::Admin::PayoutsController < Api::V1::Admin::BaseController
  include AdminListing

  RECONCILIATION_ACTIONS = %w[payout.reconciled payout.provider_result_conflict].freeze

  # GET /api/v1/admin/payouts
  def index
    scope = filtered_payouts
    counts = scope.unscope(:order).group(:status).count
    payouts, meta = admin_page(scope.includes(:organization, :event, :settlement, :connected_account)
      .order(created_at: :desc, id: :desc))
    audits = AuditLog.includes(:actor_user).where(auditable_type: "Payout", auditable_id: payouts.map(&:id),
      action: RECONCILIATION_ACTIONS).order(:id).group_by(&:auditable_id)
    render json: {
      payouts: payouts.map { |payout| payout_list_json(payout, audits.fetch(payout.id, [])) },
      meta: meta,
      status_counts: Payout.statuses.keys.index_with { |status| counts.fetch(status, 0) },
      context: listing_context
    }
  end

  def update
    payout = Payout.find(params[:id])
    evidence = params[:evidence]
    PayoutReconciler.call(payout: payout, actor: current_user, status: params[:status].to_s,
      provider_payout_id: params[:provider_payout_id],
      evidence: evidence.is_a?(ActionController::Parameters) ? evidence.permit(:reference, :confirmed_at, :reason, :conflict_audit_id, :approved_payee_confirmed).to_h : nil,
      request: request
    )
    render json: payout.attributes.slice(
      "id", "organization_id", "event_id", "settlement_id", "provider", "provider_payout_id",
      "amount_cents", "currency", "status", "paid_at"
    )
  rescue ActiveRecord::RecordNotFound
    render json: { error: "Payout not found" }, status: :not_found
  rescue PayoutReconciler::ReconciliationError => e
    render json: { error: e.message, conflict_audit_id: e.conflict_audit_id }.compact, status: :unprocessable_entity
  rescue ActiveRecord::RecordNotUnique
    message = payout&.provider == "check" ? "That check number is already recorded" : "That transfer identifier is already recorded"
    render json: { error: message }, status: :unprocessable_entity
  end

  private

  def filtered_payouts
    scope = Payout.all
    scope = scope.where(status: params[:status]) if Payout.statuses.key?(params[:status].to_s)
    scope = scope.where(organization_id: params[:organization_id]) if params[:organization_id].present?
    scope = scope.where(event_id: params[:event_id]) if params[:event_id].present?
    if (term = search_term)
      pattern = like_pattern(term)
      scope = scope.joins(:organization, :event).where(
        "organizations.name ILIKE :q OR events.title ILIKE :q OR payouts.provider_payout_id ILIKE :q", q: pattern
      )
    end
    scope
  end

  # When the list is opened from an event or organization, the screen names
  # that context and can offer balance adjustments for it.
  def listing_context
    if params[:event_id].present?
      event = Event.includes(:organization).find_by(id: params[:event_id])
      return nil unless event

      { event: { id: event.id, title: event.title, slug: event.slug },
        organization: { id: event.organization_id, name: event.organization.name, currency: event.organization.currency } }
    elsif params[:organization_id].present?
      organization = Organization.find_by(id: params[:organization_id])
      organization && { organization: { id: organization.id, name: organization.name, currency: organization.currency } }
    end
  end

  def payout_list_json(payout, audits)
    reconciliation = audits.reverse.find { |audit| audit.action == "payout.reconciled" }
    # Compared in memory (snapshot vs. details on file), once per payout.
    payee_changed = payout.provider == "check" && !payout.payee_matches_approval?
    conflict = audits.reverse.find { |audit| audit.action == "payout.provider_result_conflict" }
    payout.attributes.slice(
      "id", "provider", "provider_payout_id", "amount_cents", "currency", "status", "failure_code",
      "failure_message", "initiated_at", "paid_at", "created_at"
    ).merge(
      organization: { id: payout.organization_id, name: payout.organization.name },
      event: { id: payout.event_id, title: payout.event.title, slug: payout.event.slug },
      settlement: { id: payout.settlement_id, version: payout.settlement.version },
      # For checks, who to write it to; the check number is the transfer ID
      # and the date on the check is the confirmation time.
      payee: payout.provider == "check" ? payout.payee_snapshot : nil,
      payee_changed: payee_changed,
      current_payee: payee_changed ? payout.connected_account.check_payee : nil,
      allowed_outcomes: %w[paid failed reversed].select { |status| payout.may_reconcile_to?(status) },
      conflict_audit_id: payout.failure_code == "provider_result_conflict" ? conflict&.id : nil,
      conflict: payout.failure_code == "provider_result_conflict" && conflict ? {
        audit_id: conflict.id, occurred_at: conflict.occurred_at, recorded_before: conflict.before_data,
        provider_result: conflict.metadata["provider_result"]
      } : nil,
      last_reconciliation: reconciliation && {
        recorded_at: reconciliation.occurred_at,
        recorded_by: reconciliation.actor_user&.email,
        reference: reconciliation.metadata.dig("reconciliation", "reference"),
        reason: reconciliation.metadata.dig("reconciliation", "reason")
      }
    )
  end
end
