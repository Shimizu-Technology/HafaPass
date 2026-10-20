# frozen_string_literal: true

class Api::V1::Admin::SettingsController < Api::V1::Admin::BaseController
  FEE_TERM_FIELDS = %w[service_fee_percent service_fee_flat_cents processing_fee_bearer payout_schedule_text].freeze

  # GET /api/v1/admin/settings
  def show
    render json: settings_json(SiteSetting.instance)
  end

  # PATCH /api/v1/admin/settings
  def update
    settings = SiteSetting.instance

    # Safety: can't switch to test without test keys
    if params[:payment_mode] == "test" && !settings.can_enable_test?
      render json: { error: "Cannot enable test mode \u2014 no Stripe test keys configured" }, status: :unprocessable_entity
      return
    end

    # Safety: live money requires current, independently approved provider evidence.
    if params[:payment_mode] == "live" && !settings.can_enable_live?
      render json: { error: "Cannot enable live mode \u2014 current Stripe provider evidence is not independently approved" },
        status: :unprocessable_entity
      return
    end

    settings.assign_attributes(settings_params)
    changes = settings.changes.except("updated_at")
    fee_changes = changes.slice(*FEE_TERM_FIELDS)
    saved = SiteSetting.transaction do
      next false unless settings.save

      if changes.any?
        AuditLogger.record!(action: "site_settings.updated", auditable: settings, actor: @current_user,
          before_data: changes.transform_values { |values| values.first.to_s },
          after_data: changes.transform_values { |values| values.last.to_s }, request: request)
      end
      if changes.key?("payment_mode")
        AuditLogger.record!(action: "site_settings.payment_mode_changed", auditable: settings, actor: @current_user,
          before_data: { "payment_mode" => changes["payment_mode"].first.to_s },
          after_data: { "payment_mode" => changes["payment_mode"].last.to_s }, request: request)
      end
      if fee_changes.any?
        # Fee terms apply to orders created after this change; existing orders
        # keep their snapshotted fee and processing-fee bearer.
        AuditLogger.record!(action: "site_settings.fee_terms_updated", auditable: settings, actor: @current_user,
          before_data: fee_changes.transform_values { |values| values.first.to_s },
          after_data: fee_changes.transform_values { |values| values.last.to_s }, request: request)
      end
      true
    end
    if saved
      mode_label = { "simulate" => "Simulate", "test" => "Test (Stripe Sandbox)", "live" => "Live (Real Money)" }
      Rails.logger.info "\U0001f527 Payment mode changed to: #{mode_label[settings.payment_mode]} by #{@current_user.email}"
      render json: settings_json(settings)
    else
      render json: { errors: settings.errors.full_messages }, status: :unprocessable_entity
    end
  end

  private

  def settings_params
    params.permit(:payment_mode, :platform_name, :platform_email, :platform_phone,
                  :service_fee_percent, :service_fee_flat_cents, :processing_fee_bearer, :payout_schedule_text)
  end

  def settings_json(settings)
    {
      payment_mode: settings.payment_mode,
      platform_name: settings.platform_name,
      platform_email: settings.platform_email,
      platform_phone: settings.platform_phone,
      service_fee_percent: settings.service_fee_percent,
      service_fee_flat_cents: settings.service_fee_flat_cents,
      processing_fee_bearer: settings.processing_fee_bearer,
      payout_schedule_text: settings.payout_schedule_text,
      stripe_test_configured: settings.can_enable_test?,
      stripe_live_configured: settings.stripe_live_configured?,
      stripe_live_approved: settings.can_enable_live?
    }
  end
end
