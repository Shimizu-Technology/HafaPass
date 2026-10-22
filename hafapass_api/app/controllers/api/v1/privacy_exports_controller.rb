# frozen_string_literal: true

class Api::V1::PrivacyExportsController < ApplicationController
  skip_before_action :authenticate_user!

  def show
    item = PrivacyRequestAccess.find(params[:token])
    return render json: { error: "This export link is invalid or expired" }, status: :not_found unless item

    response.headers["Cache-Control"] = "private, no-store"
    send_data JSON.pretty_generate(PrivacyRequestProcessor.new(item).export), type: "application/json",
      disposition: "attachment", filename: "hafapass-data-#{item.id}.json"
  end
end
