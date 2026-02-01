# frozen_string_literal: true

class Api::V1::ConfigController < ApplicationController
  skip_before_action :authenticate_user!

  # GET /api/v1/config
  # Public endpoint — returns payment mode + publishable key for the frontend.
  def show
    settings = SiteSetting.instance

    render json: {
      payment_mode: settings.payment_mode,
      stripe_publishable_key: settings.stripe_publishable_key,
      platform_name: settings.platform_name,
      service_fee_percent: settings.service_fee_percent,
      service_fee_flat_cents: settings.service_fee_flat_cents
    }
  end
end
