# frozen_string_literal: true

class Api::V1::Admin::OperationsController < Api::V1::Admin::BaseController
  def index
    response.headers["Cache-Control"] = "no-store"
    render json: OperationalReview.new.call(category: params[:category], page: params[:page] || 1)
  rescue ArgumentError
    render json: { error: "Unknown operational category" }, status: :unprocessable_entity
  rescue ActiveRecord::StatementInvalid
    render json: { error: "Operational review is temporarily unavailable" }, status: :service_unavailable
  end
end
