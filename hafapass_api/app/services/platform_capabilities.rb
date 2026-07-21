# frozen_string_literal: true

require "digest"

class PlatformCapabilities
  DEFINITIONS = {
    "stripe_live" => {
      label: "Stripe live payments",
      required_env: %w[STRIPE_LIVE_SECRET_KEY STRIPE_LIVE_PUBLISHABLE_KEY STRIPE_WEBHOOK_SECRET PROVIDER_CONFIGURATION_REVISION],
      controls: %w[territory_and_entity_approved signed_webhooks_tested sandbox_matrix_complete
        reconciliation_zero_variance refunds_and_disputes_tested browser_loss_and_idempotency_tested]
    },
    "resend_production" => {
      label: "Resend production email",
      required_env: %w[RESEND_API_KEY RESEND_WEBHOOK_SECRET MAILER_FROM_EMAIL PROVIDER_CONFIGURATION_REVISION],
      controls: %w[domain_verified signed_webhooks_tested deduplication_tested delivery_and_retry_tested
        bounce_complaint_and_suppression_tested support_resend_tested]
    },
    "apple_wallet" => {
      label: "Apple Wallet",
      required_env: %w[APPLE_PASS_TYPE_IDENTIFIER APPLE_TEAM_IDENTIFIER APPLE_PASS_CERTIFICATE_BASE64
        APPLE_WWDR_CERTIFICATE_BASE64 APPLE_PASS_ICON_PATH PROVIDER_CONFIGURATION_REVISION],
      controls: %w[issuer_approved signing_tested device_install_tested invalidation_behavior_tested]
    },
    "google_wallet" => {
      label: "Google Wallet",
      required_env: %w[GOOGLE_WALLET_ISSUER_ID GOOGLE_WALLET_SERVICE_ACCOUNT_EMAIL GOOGLE_WALLET_PRIVATE_KEY
        PROVIDER_CONFIGURATION_REVISION],
      controls: %w[issuer_approved class_approved signing_tested device_install_tested invalidation_behavior_tested]
    },
    "policy_register" => {
      label: "Production policy register",
      required_env: [],
      controls: %w[counsel_approved accounting_approved privacy_approved effective_dates_approved
        reacceptance_rules_approved retention_deletion_and_legal_hold_approved]
    }
  }.freeze

  class << self
    def names
      DEFINITIONS.keys
    end

    def definition(name)
      DEFINITIONS.fetch(name.to_s) { raise ArgumentError, "Unknown platform capability" }
    end

    def required_controls(name)
      definition(name).fetch(:controls)
    end

    def configured?(name)
      name = name.to_s
      return true if name == "policy_register"

      definition(name).fetch(:required_env).all? { |key| ENV[key].present? } && provider_specific_configuration_valid?(name)
    end

    def configuration_digest(name)
      name = name.to_s
      facts = if name == "policy_register"
        { version: PolicyRegistry.version, registry_digest: PolicyRegistry.registry_digest }
      else
        {
          revision: ENV["PROVIDER_CONFIGURATION_REVISION"].to_s,
          configured: configured?(name),
          credential_fingerprint: credential_fingerprint(name),
          public_identifiers: public_identifiers(name)
        }
      end
      Digest::SHA256.hexdigest(JSON.generate({ capability: name, facts: facts }))
    end

    def active_approval(name, at: Time.current)
      name = name.to_s
      revoked_ids = PlatformCapabilityReview.where(capability: name).revocations.select(:parent_review_id)
      PlatformCapabilityReview.where(capability: name).approvals
        .where("effective_at <= ? AND expires_at > ?", at, at)
        .where.not(id: revoked_ids)
        .order(created_at: :desc)
        .detect { |review| review.configuration_digest == configuration_digest(name) }
    rescue ActiveRecord::StatementInvalid
      nil
    end

    def enabled?(name, at: Time.current)
      configured?(name) && active_approval(name, at: at).present?
    end

    def pending_submission(name)
      decided_ids = PlatformCapabilityReview.where(capability: name, decision: [:approval, :rejection])
        .select(:parent_review_id)
      PlatformCapabilityReview.where(capability: name).decision_submission.where.not(id: decided_ids)
        .order(created_at: :desc).first
    end

    def latest_approval(name)
      PlatformCapabilityReview.where(capability: name).approvals.order(created_at: :desc).first
    end

    def status(name)
      name = name.to_s
      configured = configured?(name)
      approval = active_approval(name)
      {
        capability: name,
        label: definition(name).fetch(:label),
        configured: configured,
        approved: approval.present?,
        enabled: configured && approval.present?,
        status: capability_status(configured, approval),
        required_controls: required_controls(name),
        configuration_digest: configuration_digest(name),
        pending_submission: pending_submission(name),
        latest_approval: latest_approval(name)
      }
    end

    def readiness
      statuses = names.index_with { |name| status(name) }
      required = %w[resend_production policy_register]
      required << "stripe_live" if SiteSetting.instance.live_mode?
      ready = required.all? { |name| statuses.fetch(name).fetch(:enabled) }
      {
        ready: ready,
        status: ready ? "approved" : "approval_required",
        capabilities: statuses.transform_values { |item| item.slice(:configured, :approved, :enabled, :status) }
      }
    end

    private

    def capability_status(configured, approval)
      return "not_configured" unless configured
      return "approved" if approval

      "disabled_pending_approval"
    end

    def provider_specific_configuration_valid?(name)
      return ENV["GOOGLE_WALLET_CLASS_REVIEW_STATUS"] == "APPROVED" if name == "google_wallet"

      true
    end

    def public_identifiers(name)
      keys = case name
      when "stripe_live" then %w[STRIPE_LIVE_PUBLISHABLE_KEY]
      when "resend_production" then %w[MAILER_FROM_EMAIL]
      when "apple_wallet" then %w[APPLE_PASS_TYPE_IDENTIFIER APPLE_TEAM_IDENTIFIER APPLE_PASS_ICON_PATH]
      when "google_wallet" then %w[GOOGLE_WALLET_ISSUER_ID GOOGLE_WALLET_SERVICE_ACCOUNT_EMAIL GOOGLE_WALLET_CLASS_REVIEW_STATUS]
      else []
      end
      keys.to_h { |key| [key, ENV[key].to_s] }
    end

    def credential_fingerprint(name)
      values = definition(name).fetch(:required_env).to_h { |key| [key, ENV[key].to_s] }
      Digest::SHA256.hexdigest(JSON.generate(values))
    end
  end
end
