# frozen_string_literal: true

module ConnectedAccounts
  class Manager
    class AccountError < StandardError; end

    INDEPENDENT_APPROVAL_REQUIREMENT = "independent_readiness_approval"

    INITIAL_REQUIREMENTS = {
      "paypal" => %w[partner_approval seller_onboarding business_verification payout_method],
      "manual" => %w[business_verification bank_account_review payout_agreement],
      "stripe" => %w[guam_eligibility_review provider_onboarding],
      "check" => %w[business_verification payee_details_review payout_agreement]
    }.freeze

    CHECK_DETAIL_FIELDS = %w[payee_name delivery_method mailing_address pickup_note memo].freeze

    def self.start!(organization:, provider:, actor:, request: nil, payout_details: nil)
      provider = provider.to_s
      unless INITIAL_REQUIREMENTS.key?(provider)
        raise AccountError, "Choose check, bank transfer, PayPal, or Stripe"
      end

      account = organization.connected_accounts.find_or_initialize_by(provider: provider)
      if account.persisted? && provider == "check"
        # Restarting a check setup only updates who the check is for.
        return update_payout_details!(account: account, payout_details: payout_details, actor: actor, request: request)
      end

      account.assign_attributes(
        status: :onboarding,
        requirements_due: INITIAL_REQUIREMENTS.fetch(provider),
        capabilities: provider_capabilities(provider),
        last_synced_at: Time.current
      )
      account.payout_details = normalize_check_details(payout_details) if provider == "check"
      account.save!
      AuditLogger.record!(
        action: "connected_account.onboarding_started",
        auditable: account,
        actor: actor,
        organization: organization,
        after_data: readiness_snapshot(account),
        request: request
      )
      account
    rescue ActiveRecord::RecordInvalid => e
      raise AccountError, e.record.errors.full_messages.to_sentence
    end

    # Changing who a check is written to (or where it goes) is a change to
    # where money goes, so any earlier readiness approval stops applying.
    def self.update_payout_details!(account:, payout_details:, actor:, request: nil)
      raise AccountError, "Only check payouts have payee details" unless account.provider == "check"
      details = normalize_check_details(payout_details)
      ensure_no_check_in_flight!(account.organization)

      before_data = readiness_snapshot(account)
      provider_configuration_before = account.provider_configuration_digest
      account.payout_details = details
      if account.provider_configuration_digest != provider_configuration_before
        account.readiness_revision += 1
        account.status = derived_status(account, disabled: account.status_disabled?)
      end
      account.last_synced_at = Time.current
      account.save!
      AuditLogger.record!(
        action: "connected_account.payout_details_updated",
        auditable: account,
        actor: actor,
        organization: account.organization,
        before_data: before_data,
        after_data: readiness_snapshot(account),
        request: request
      )
      account
    rescue ActiveRecord::RecordInvalid => e
      raise AccountError, e.record.errors.full_messages.to_sentence
    end

    CHECK_IN_FLIGHT_MESSAGE = "A check payout is in progress. You can change payee details after HåfaPass records it."

    # The approved payee is what a check in flight is written to; changing it
    # mid-payout would leave the admin unable to record the real check.
    def self.ensure_no_check_in_flight!(organization)
      in_flight = organization.payouts.where(provider: "check", status: [:pending, :processing]).exists?
      raise AccountError, CHECK_IN_FLIGHT_MESSAGE if in_flight
    end

    def self.normalize_check_details(details)
      values = details.respond_to?(:to_unsafe_h) ? details.to_unsafe_h : details
      raise AccountError, "Enter who the check is for and how it reaches you" unless values.is_a?(Hash)

      values = values.stringify_keys.slice(*CHECK_DETAIL_FIELDS).transform_values { |value| value.to_s.strip }
      values.delete("mailing_address") unless values["delivery_method"] == "mail"
      values.delete("pickup_note") unless values["delivery_method"] == "pickup"
      values.compact_blank
    end
    private_class_method :normalize_check_details

    def self.sync!(account:, attributes:, actor:, request: nil)
      before_data = readiness_snapshot(account)
      provider_configuration_before = account.provider_configuration_digest
      allowed = attributes.to_h.symbolize_keys.slice(
        :provider_account_id, :charges_enabled, :payouts_enabled, :details_submitted,
        :requirements_due, :capabilities, :disabled
      )
      if allowed.key?(:requirements_due)
        allowed[:requirements_due] = Array(allowed[:requirements_due]).filter_map { |value| value.to_s.strip.presence }
      end
      disabled_value = allowed.delete(:disabled)
      disabled = if disabled_value.nil?
        account.status_disabled?
      else
        ActiveModel::Type::Boolean.new.cast(disabled_value)
      end
      account.assign_attributes(allowed)
      account.status = derived_status(account, disabled: disabled)
      if account.provider_configuration_digest != provider_configuration_before
        account.readiness_revision += 1
        account.status = derived_status(account, disabled: disabled)
      end
      account.last_synced_at = Time.current
      account.save!
      AuditLogger.record!(
        action: "connected_account.synced",
        auditable: account,
        actor: actor,
        organization: account.organization,
        before_data: before_data,
        after_data: readiness_snapshot(account),
        request: request
      )
      account
    rescue ActiveRecord::RecordInvalid => e
      raise AccountError, e.record.errors.full_messages.to_sentence
    end

    def self.refresh_readiness!(account:, actor:, request: nil, action: "connected_account.readiness_recomputed")
      before_data = readiness_snapshot(account)
      account.requirements_due = normalized_requirements(account)
      account.status = derived_status(account, disabled: account.status_disabled?)
      account.last_synced_at = Time.current
      account.save!
      AuditLogger.record!(
        action: action,
        auditable: account,
        actor: actor,
        organization: account.organization,
        before_data: before_data,
        after_data: readiness_snapshot(account),
        request: request
      )
      account
    rescue ActiveRecord::RecordInvalid => e
      raise AccountError, e.record.errors.full_messages.to_sentence
    end

    def self.derived_status(account, disabled: false)
      return :disabled if disabled
      account.requirements_due = normalized_requirements(account)
      if account.externally_ready? && account.active_payment_readiness_approval
        return :ready
      end
      return :requirements_due if account.details_submitted? && account.requirements_due.present?

      :onboarding
    end
    private_class_method :derived_status

    def self.normalized_requirements(account)
      requirements = Array(account.requirements_due).filter_map { |value| value.to_s.strip.presence }
      provider_requirements = requirements - [INDEPENDENT_APPROVAL_REQUIREMENT]
      requirements = provider_requirements
      if account.charges_enabled? && account.payouts_enabled? && account.details_submitted? && provider_requirements.blank?
        unless account.active_payment_readiness_approval
          requirements << INDEPENDENT_APPROVAL_REQUIREMENT
        end
      end
      requirements.uniq
    end
    private_class_method :normalized_requirements

    def self.provider_capabilities(provider)
      {
        "paypal" => { automated_payouts: true, partner_approval_required: true, guam_documented: true },
        "manual" => { automated_payouts: false, reconciliation_required: true, guam_documented: true },
        "stripe" => { automated_payouts: true, guam_eligibility_required: true, guam_documented: false },
        "check" => { automated_payouts: false, reconciliation_required: true, payment_method: "check",
                     guam_documented: true }
      }.fetch(provider)
    end
    private_class_method :provider_capabilities

    def self.readiness_snapshot(account)
      account.attributes.slice(
        "provider", "provider_account_id", "status", "charges_enabled", "payouts_enabled",
        "details_submitted", "requirements_due", "capabilities", "readiness_revision", "last_synced_at",
        "payout_details"
      ).tap { |data| data.delete("payout_details") unless account.provider == "check" }
    end
    private_class_method :readiness_snapshot
  end
end
