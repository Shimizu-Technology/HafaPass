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

    # Safety: test and live need every credential for that mode, and live also
    # needs RAILS_ENV=production and an approved stripe_live capability. The
    # checklist explains what is missing; nothing switches until it is met.
    requested_mode = params[:payment_mode].presence
    switching = requested_mode && requested_mode != settings.payment_mode
    if switching && requested_mode == "simulate" && Rails.env.production?
      render json: { error: "Production uses test or live payments only" }, status: :unprocessable_entity
      return
    end
    if switching && %w[test live].include?(requested_mode)
      readiness = PaymentModeReadiness.call(requested_mode)
      unless readiness[:ready]
        missing = readiness[:checks].reject { |check| check[:met] }.map { |check| check[:label] }
        render json: { error: "Cannot switch to #{requested_mode} payments yet. Still needed: #{missing.join('; ')}.",
          readiness: readiness }, status: :unprocessable_entity
        return
      end
      begin
        StripeService.verify_platform_credentials!(requested_mode)
      rescue StripeService::PaymentError => e
        render json: { error: "Cannot switch to #{requested_mode} payments: #{e.message}." }, status: :unprocessable_entity
        return
      end
    end

    # The row lock serializes concurrent switches and edits; the slower
    # readiness and Stripe checks above run before taking it.
    refusal = nil
    saved = settings.with_lock do
      # with_lock reloaded the row. A mode change that was not checked above
      # (someone else switched meanwhile) or simulate in production is refused.
      if requested_mode && requested_mode != settings.payment_mode &&
          (!switching || (requested_mode == "simulate" && Rails.env.production?))
        refusal = "The payment mode changed while you were saving. Reload the page and try again."
        next false
      end
      settings.assign_attributes(settings_params)
      changes = settings.changes.except("updated_at")
      fee_changes = changes.slice(*FEE_TERM_FIELDS)
      next false unless settings.save

      if changes.any?
        AuditLogger.record!(action: "site_settings.updated", auditable: settings, actor: @current_user,
          before_data: changes.transform_values { |values| values.first.to_s },
          after_data: changes.transform_values { |values| values.last.to_s }, request: request)
      end
      if changes.key?("payment_mode")
        AuditLogger.record!(action: "site_settings.payment_mode_changed", auditable: settings, actor: @current_user,
          before_data: { "payment_mode" => changes["payment_mode"].first.to_s },
          after_data: { "payment_mode" => changes["payment_mode"].last.to_s },
          metadata: payment_mode_audit_metadata(changes["payment_mode"].last.to_s), request: request)
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
    if refusal
      render json: { error: refusal }, status: :conflict
    elsif saved
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
                  :service_fee_percent, :service_fee_flat_cents, :processing_fee_bearer, :payout_schedule_text,
                  :business_mailing_address)
  end

  def settings_json(settings)
    {
      payment_mode: settings.payment_mode,
      platform_name: settings.platform_name,
      platform_email: settings.platform_email,
      platform_phone: settings.platform_phone,
      business_mailing_address: settings.business_mailing_address,
      service_fee_percent: settings.service_fee_percent,
      service_fee_flat_cents: settings.service_fee_flat_cents,
      processing_fee_bearer: settings.processing_fee_bearer,
      payout_schedule_text: settings.payout_schedule_text,
      stripe_test_configured: settings.can_enable_test?,
      stripe_live_configured: settings.stripe_live_configured?,
      stripe_live_approved: settings.can_enable_live?,
      environment: Rails.env.to_s,
      payment_mode_readiness: PaymentModeReadiness.all,
      payments_by_mode: Payment.where(provider: "stripe", provider_environment: %w[test live])
        .group(:provider_environment).count
    }
  end

  # Records the platform accounts in effect so reconciliation can tell which
  # Stripe account a mode change pointed new orders at. IDs only, no secrets.
  def payment_mode_audit_metadata(mode)
    {
      "rails_env" => Rails.env.to_s,
      "platform_account_id" => StripeService.platform_account_id(mode),
      "provider_configuration_revision" => ENV["PROVIDER_CONFIGURATION_REVISION"].to_s.presence,
      "existing_orders_keep_their_mode" => true
    }.compact
  end
end
