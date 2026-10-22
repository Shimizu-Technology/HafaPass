# frozen_string_literal: true

class Api::V1::Admin::LegalHoldsController < Api::V1::Admin::BaseController
  def index
    response.headers["Cache-Control"] = "private, no-store"
    render json: { holds: LegalHold.order(created_at: :desc).limit(200).map { |hold| serialize(hold) } }
  end

  def create
    hold = LegalHold.place!(scope_type: params[:scope_type], scope_value: params[:scope_value],
      reason: params[:reason], actor: current_user, request: request)
    render json: serialize(hold), status: :created
  rescue ActiveRecord::RecordInvalid => error
    render json: { errors: error.record.errors.full_messages }, status: :unprocessable_entity
  rescue ActiveRecord::RecordNotUnique
    render json: { errors: ["An active hold already covers this scope"] }, status: :unprocessable_entity
  end

  def release
    hold = LegalHold.find(params[:id])
    hold.release!(actor: current_user, request: request)
    render json: serialize(hold)
  end

  private

  def serialize(hold)
    hold.as_json(only: [:id, :scope_type, :scope_value, :reason, :placed_by_id, :created_at,
      :released_at, :released_by_id])
  end
end
