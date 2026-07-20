# frozen_string_literal: true

class Api::V1::Support::BaseController < ApplicationController
  before_action :require_support!

  private

  def require_support!
    return if current_user&.admin? || current_user&.support?

    render json: { error: "Support access required" }, status: :forbidden
  end
end
