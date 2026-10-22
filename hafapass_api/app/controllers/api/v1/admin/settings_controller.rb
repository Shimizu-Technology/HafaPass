# frozen_string_literal: true

class Api::V1::Admin::SettingsController < Api::V1::Admin::BaseController
  FEE_TERM_FIELDS = %w[service_fee_percent service_fee_flat_cents processing_fee_bearer payout_schedule_text].freeze

  # GET /api/v1/admin/settings
  def show
    render json: settings_json(SiteSetting.instance)
  end

  def fee_change_preview
    settings = SiteSetting.instance
    proposed_terms = params.permit(*FEE_TERM_FIELDS).to_h
    render json: FeeChange.notice_preview.merge(
      minimum_notice_days: settings.fee_notice_days,
      registry_digest: FeeChange.proposed_registry_digest(settings: settings, attributes: proposed_terms))
  rescue ActiveRecord::RecordInvalid => e
    render json: { error: e.record.errors.full_messages.to_sentence }, status: :unprocessable_content
  end

  # PATCH /api/v1/admin/settings
  def update
    settings = SiteSetting.instance
    requested_fee_terms = settings_params.to_h.slice(*FEE_TERM_FIELDS)
    changed_fee_terms = requested_fee_terms.any? do |field, value|
      field == "service_fee_percent" ? settings.service_fee_percent.to_d != value.to_d :
        settings.public_send(field).to_s != value.to_s
    end
    if changed_fee_terms
      begin
        effective_at = Time.iso8601(params.require(:effective_at).to_s)
        minimum = settings.fee_notice_days.days.from_now
        if effective_at < minimum
          return render json: { error: "Effective date must be at least #{settings.fee_notice_days} days ahead" },
            status: :unprocessable_entity
        end
      rescue ActionController::ParameterMissing, ArgumentError
        return render json: { error: "A valid effective date with time zone is required for fee changes" },
          status: :unprocessable_entity
      end
    end

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
      settings.assign_attributes(settings_params.except(*FEE_TERM_FIELDS))
      changes = settings.changes.except("updated_at")
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
      if changes.key?("retention_purge_enabled")
        AuditLogger.record!(action: "site_settings.retention_purge_changed", auditable: settings, actor: @current_user,
          before_data: { "retention_purge_enabled" => changes["retention_purge_enabled"].first },
          after_data: { "retention_purge_enabled" => changes["retention_purge_enabled"].last }, request: request)
      end
      if changed_fee_terms
        FeeChange.schedule!(settings: settings, attributes: requested_fee_terms, effective_at: effective_at,
          actor: @current_user, request: request, future_terms_approved: params[:future_terms_approved] == true || params[:future_terms_approved] == "true",
          approved_registry_digest: params[:approved_registry_digest])
      end
      true
    end
    if refusal
      render json: { error: refusal }, status: :conflict
    elsif saved
      mode_label = { "simulate" => "Simulate", "test" => "Test (Stripe Sandbox)", "live" => "Live (Real Money)" }
      Rails.logger.info "\U0001f527 Payment mode changed to: #{mode_label[settings.payment_mode]} by #{@current_user.email}"
      render json: settings_json(settings.reload)
    else
      render json: { errors: settings.errors.full_messages }, status: :unprocessable_entity
    end
  rescue ArgumentError, ActiveRecord::RecordInvalid, ActiveRecord::RecordNotUnique => e
    render json: { error: e.message }, status: :unprocessable_entity
  end

  private

  def settings_params
    params.permit(:payment_mode, :platform_name, :platform_email, :platform_phone,
                  :service_fee_percent, :service_fee_flat_cents, :processing_fee_bearer, :payout_schedule_text,
                  :business_mailing_address, :retention_purge_enabled, :fee_notice_days)
  end

  def settings_json(settings)
    {
      payment_mode: settings.payment_mode,
      retention_purge_enabled: settings.retention_purge_enabled,
      retention_dry_run: DataRetention.dry_run?,
      retention_destructive_enabled: !DataRetention.dry_run?,
      platform_name: settings.platform_name,
      platform_email: settings.platform_email,
      platform_phone: settings.platform_phone,
      business_mailing_address: settings.business_mailing_address,
      service_fee_percent: settings.service_fee_percent,
      service_fee_flat_cents: settings.service_fee_flat_cents,
      processing_fee_bearer: settings.processing_fee_bearer,
      payout_schedule_text: settings.payout_schedule_text,
      fee_notice_days: settings.fee_notice_days,
      policy_register_approved: PlatformCapabilities.enabled?("policy_register"),
      **FeeChange.notice_preview,
      pending_fee_change: FeeChange.pending.order(:id).last&.as_json(only: [:id, :old_terms, :new_terms, :effective_at, :created_at]),
      blocked_fee_change: FeeChange.where.not(blocked_at: nil).order(:blocked_at).last&.as_json(only: [:id, :effective_at, :blocked_at, :activation_error]),
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
