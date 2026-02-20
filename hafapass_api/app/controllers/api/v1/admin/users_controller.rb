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

    # Prevent self-role-change
    if user.id == @current_user.id
      render json: { error: "Cannot modify your own role" }, status: :forbidden
      return
    end

    # Prevent demoting the last admin
    if user.admin? && params[:role] != "admin" && User.where(role: :admin).count == 1
      render json: { error: "Cannot demote the last admin" }, status: :unprocessable_entity
      return
    end

    if user.update(user_params)
      render json: user_json(user)
    else
      render json: { errors: user.errors.full_messages }, status: :unprocessable_entity
    end
  end

  private

  def user_params
    params.permit(:role)
  end

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
        business_name: u.organizer_profile.business_name
      } : nil
    }
  end
end
