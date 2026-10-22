# frozen_string_literal: true

class Api::V1::Admin::BalanceAdjustmentsController < Api::V1::Admin::BaseController
  include AdminListing

  # Direction is part of the kind for manual entries: a credit or reserve
  # release adds to the organizer's balance, a debit or reserve hold takes
  # from it. A mismatched sign would silently do the opposite.
  SIGNED_KINDS = { "manual_credit" => 1, "reserve_release" => 1, "manual_debit" => -1, "reserve_hold" => -1 }.freeze

  # GET /api/v1/admin/balance_adjustments
  def index
    scope = BalanceAdjustment.all
    scope = scope.where(organization_id: params[:organization_id]) if params[:organization_id].present?
    scope = scope.where(event_id: params[:event_id]) if params[:event_id].present?
    scope = scope.where(kind: params[:kind]) if BalanceAdjustment::KINDS.include?(params[:kind].to_s)
    scope = scope.where(status: params[:status]) if BalanceAdjustment.statuses.key?(params[:status].to_s)
    adjustments, meta = admin_page(scope.includes(:organization, :event, :created_by_user, :reversal)
      .order(created_at: :desc, id: :desc))
    render json: { balance_adjustments: adjustments.map { |adjustment| adjustment_list_json(adjustment) }, meta: meta }
  end

  def create
    sign = SIGNED_KINDS[params[:kind].to_s]
    # Dispute, processing and payout-reversal kinds are posted by the system.
    unless sign
      return render json: { errors: ["Kind must be one of #{SIGNED_KINDS.keys.to_sentence(last_word_connector: ", or ")}"] },
        status: :unprocessable_entity
    end

    amount = params[:amount_cents].to_s
    if !amount.match?(/\A-?\d+\z/) || (amount.to_i <=> 0) != sign
      return render json: { errors: ["Amount must be #{sign.positive? ? "positive" : "negative"} for #{params[:kind].to_s.humanize.downcase}"] },
        status: :unprocessable_entity
    end

    return render json: { error: BackupWithholding::TIN_WARNING }, status: :unprocessable_entity unless BackupWithholding.safe_text?(params[:reason])
    organization = Organization.find(params[:organization_id])
    event = organization.events.find(params[:event_id]) if params[:event_id].present?
    adjustment = organization.balance_adjustments.create!(
      event: event,
      order_id: params[:order_id],
      dispute_id: params[:dispute_id],
      created_by_user: current_user,
      kind: params[:kind],
      amount_cents: params[:amount_cents],
      currency: organization.currency,
      status: :posted,
      reason: params[:reason],
      effective_at: params[:effective_at].presence || Time.current
    )
    AuditLogger.record!(
      action: "balance_adjustment.posted",
      auditable: adjustment,
      actor: current_user,
      organization: organization,
      after_data: adjustment_json(adjustment),
      request: request
    )
    render json: adjustment_json(adjustment), status: :created
  rescue ActiveRecord::RecordNotFound
    render json: { error: "Organization or event not found" }, status: :not_found
  rescue ActiveRecord::RecordInvalid => e
    render json: { errors: e.record.errors.full_messages }, status: :unprocessable_entity
  end

  def destroy
    return render json: { error: BackupWithholding::TIN_WARNING }, status: :unprocessable_entity unless BackupWithholding.safe_text?(params[:reason])
    adjustment = BalanceAdjustment.status_posted.find(params[:id])
    reversal = nil
    BalanceAdjustment.transaction do
      adjustment.lock!
      reversal = adjustment.organization.balance_adjustments.create!(
        event: adjustment.event,
        order: adjustment.order,
        dispute: adjustment.dispute,
        created_by_user: current_user,
        reversed_by_user: current_user,
        reversal_of: adjustment,
        kind: reversal_kind(adjustment),
        amount_cents: -adjustment.amount_cents,
        currency: adjustment.currency,
        status: :posted,
        reason: params[:reason].presence || "Reversal of adjustment #{adjustment.id}",
        effective_at: Time.current
      )
      adjustment.update!(status: :reversed, reversed_by_user: current_user)
    end
    AuditLogger.record!(
      action: "balance_adjustment.reversed",
      auditable: reversal,
      actor: current_user,
      organization: adjustment.organization,
      metadata: { original_adjustment_id: adjustment.id },
      request: request
    )
    render json: adjustment_json(reversal), status: :created
  rescue ActiveRecord::RecordNotUnique
    render json: { error: "This adjustment was already reversed" }, status: :conflict
  rescue ActiveRecord::RecordNotFound
    render json: { error: "Posted adjustment not found" }, status: :not_found
  rescue ActiveRecord::RecordInvalid => e
    render json: { errors: e.record.errors.full_messages }, status: :unprocessable_entity
  end

  private

  def reversal_kind(adjustment)
    return "reserve_release" if adjustment.kind == "reserve_hold"
    return "reserve_hold" if adjustment.kind == "reserve_release"

    adjustment.amount_cents.positive? ? "manual_debit" : "manual_credit"
  end

  def adjustment_list_json(adjustment)
    adjustment_json(adjustment).merge(
      organization: { id: adjustment.organization_id, name: adjustment.organization.name },
      event: adjustment.event && { id: adjustment.event_id, title: adjustment.event.title },
      created_by: adjustment.created_by_user&.email,
      reversed_by_id: adjustment.reversal&.id
    )
  end

  def adjustment_json(adjustment)
    adjustment.attributes.slice(
      "id", "organization_id", "event_id", "order_id", "dispute_id", "kind", "amount_cents",
      "currency", "status", "reason", "effective_at", "reversal_of_id", "created_at"
    )
  end
end
