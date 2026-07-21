# frozen_string_literal: true

class Api::V1::Admin::UsersController < Api::V1::Admin::BaseController
  # GET /api/v1/admin/users
  def index
    users = User.includes(:organizer_profile, :orders)

    if params[:search].present?
      q = "%#{params[:search]}%"
      users = users.where("email ILIKE :q OR first_name ILIKE :q OR last_name ILIKE :q", q: q)
    end
    users = users.where(role: params[:role]) if params[:role].present?

    users = users.order(created_at: :desc)

    page = (params[:page] || 1).to_i
    per_page = (params[:per_page] || 20).to_i
    total = users.count
    users = users.offset((page - 1) * per_page).limit(per_page)

    render json: {
      users: users.map { |u| user_json(u) },
      meta: { page: page, per_page: per_page, total: total, total_pages: (total.to_f / per_page).ceil }
    }
  end

  # PATCH /api/v1/admin/users/:id
  def update
    user = User.find(params[:id])
    requested_role = params[:role].to_s

    unless User.roles.key?(requested_role)
      render json: { error: "Invalid role" }, status: :unprocessable_entity
      return
    end

    # Prevent self-role-change
    if user.id == @current_user.id
      render json: { error: "Cannot modify your own role" }, status: :forbidden
      return
    end

    # Prevent demoting the last admin
    if user.admin? && requested_role != "admin" && User.where(role: :admin).count == 1
      render json: { error: "Cannot demote the last admin" }, status: :unprocessable_entity
      return
    end

    previous_role = user.role
    if user.update(role: requested_role)
      AuditLogger.record!(
        action: "user.role_updated",
        auditable: user,
        actor: current_user,
        before_data: { role: previous_role },
        after_data: { role: user.role },
        request: request
      )
      render json: user_json(user)
    else
      render json: { errors: user.errors.full_messages }, status: :unprocessable_entity
    end
  end

  private

  def user_json(u)
    {
      id: u.id,
      email: u.email,
      first_name: u.first_name,
      last_name: u.last_name,
      role: u.role,
      created_at: u.created_at,
      orders_count: u.orders.size,
      organizer_profile: u.organizer_profile ? {
        id: u.organizer_profile.id,
        business_name: u.organizer_profile.business_name,
        verification_status: u.organizer_profile.verification_status,
        verification_requested_at: u.organizer_profile.verification_requested_at,
        policy_accepted: u.organizer_profile.policy_accepted?,
        payout_ready: u.organizer_profile.organization.payout_ready?,
        verification_notes: u.organizer_profile.verification_notes,
        connected_account: connected_account_json(
          u.organizer_profile.organization.payout_account || u.organizer_profile.organization.connected_accounts.first
        )
      } : nil
    }
  end

  def connected_account_json(account)
    return unless account

    account.attributes.slice(
      "id", "provider", "provider_account_id", "status", "charges_enabled", "payouts_enabled",
      "details_submitted", "requirements_due", "last_synced_at"
    ).merge(
      payout_ready: account.payout_ready?,
      readiness_submission: payment_readiness_review_json(account.pending_payment_readiness_submission),
      readiness_approval: payment_readiness_review_json(account.latest_payment_readiness_approval),
      readiness_approval_active: account.active_payment_readiness_approval.present?
    )
  end

  def payment_readiness_review_json(review)
    return unless review

    review.attributes.slice(
      "id", "actor_user_id", "decision", "evidence_reference", "evidence_digest",
      "provider_state_digest",
      "provider_approval_reference", "merchant_of_record", "fee_tax_schedule_reference",
      "liability_schedule_reference", "controls", "effective_at", "expires_at", "created_at"
    )
  end
end
