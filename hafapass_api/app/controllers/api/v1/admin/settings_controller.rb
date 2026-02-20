# frozen_string_literal: true

class Api::V1::Admin::SettingsController < Api::V1::Admin::BaseController

  # GET /api/v1/admin/settings
  def show
    render json: settings_json(SiteSetting.instance)
  end

  # PATCH /api/v1/admin/settings
  def update
    settings = SiteSetting.instance

    # Safety: can't switch to test without test keys
    if params[:payment_mode] == 'test' && !settings.can_enable_test?
      render json: { error: "Cannot enable test mode \u2014 no Stripe test keys configured" }, status: :unprocessable_entity
      return
    end

    # Safety: can't switch to live without live keys
    if params[:payment_mode] == 'live' && !settings.can_enable_live?
      render json: { error: "Cannot enable live mode \u2014 STRIPE_LIVE_SECRET_KEY not configured" }, status: :unprocessable_entity
      return
    end

    if settings.update(settings_params)
      mode_label = { 'simulate' => 'Simulate', 'test' => 'Test (Stripe Sandbox)', 'live' => 'Live (Real Money)' }
      Rails.logger.info "\U0001f527 Payment mode changed to: #{mode_label[settings.payment_mode]} by #{@current_user.email}"
      render json: settings_json(settings)
    else
      render json: { errors: settings.errors.full_messages }, status: :unprocessable_entity
    end
  end

  private

  def settings_params
    params.permit(:payment_mode, :platform_name, :platform_email, :platform_phone,
                  :service_fee_percent, :service_fee_flat_cents)
  end

  def settings_json(settings)
    {
      payment_mode: settings.payment_mode,
      platform_name: settings.platform_name,
      platform_email: settings.platform_email,
      platform_phone: settings.platform_phone,
      service_fee_percent: settings.service_fee_percent,
      service_fee_flat_cents: settings.service_fee_flat_cents,
      stripe_test_configured: settings.can_enable_test?,
      stripe_live_configured: settings.can_enable_live?
    }
  end
end
