# frozen_string_literal: true

class Api::V1::Admin::BaseController < ApplicationController
  before_action :require_admin!

  private

  def require_admin!
    unless @current_user&.admin?
      render json: { error: "Admin access required" }, status: :forbidden
    end
  end
end
