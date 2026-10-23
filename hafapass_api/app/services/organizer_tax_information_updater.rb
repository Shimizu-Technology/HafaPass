# frozen_string_literal: true

class OrganizerTaxInformationUpdater
  class TaxError < StandardError; end

  def self.call(organization:, attributes:, actor:, request: nil)
    organization.with_lock do
      if organization.payouts.where(status: [:pending, :processing, :held]).exists?
        raise TaxError, "A payout is pending, in progress or on hold. You can change tax information after HåfaPass resolves it."
      end
      if EncryptionConfiguration.keys(environment: Rails.env).nil?
        raise TaxError, "Tax information is unavailable until secure encryption is configured. Please try again later."
      end
      values = attributes.to_h.symbolize_keys
      unless ActiveModel::Type::Boolean.new.cast(values.delete(:certified)) == true
        raise TaxError, "Confirm the tax certification before saving"
      end
      record = organization.organizer_tax_information || organization.build_organizer_tax_information
      previous_identity = record.persisted? ? record.current_identity_digest : nil
      record.assign_attributes(values.slice(:legal_name, :business_name, :tax_classification, :tin_type,
        :tin, :mailing_address, :exempt_payee_code, :signer_name).transform_values { |value| value.to_s.strip })
      record.certified_at = Time.current
      record.certification_version = OrganizerTaxInformation::CERTIFICATION_VERSION
      identity_changed = previous_identity != record.current_identity_digest
      record.b_notice_identity_digest ||= previous_identity if record.b_notice_stage == "second" && identity_changed
      second_notice = record.b_notice_stage == "second" && !record.irs_validation_current?
      # An unvalidated second notice remains open. A replacement identity
      # must be matched or document-validated before it can be paid.
      record.tin_match_status = second_notice && !record.second_notice_identity_changed? ? "mismatch" : "unverified"
      record.tin_match_result_code = nil
      record.tin_matched_at = nil
      record.tin_match_identity_digest = nil
      unless second_notice || (record.b_notice_stage == "second" && identity_changed)
        record.b_notice_sent_at = nil
        record.b_notice_response_due_on = nil
        record.irs_notice_received_on = nil
        record.b_notice_send_due_on = nil
      end
      # A certified W-9 resolves a first notice, while preserving its stage
      # and first-receipt date for the three-year recurrence rule.
      record.backup_withholding_flag = false unless second_notice
      record.backup_withholding_reason = nil unless second_notice
      record.save!
      # Invalidate every payout method approval, including prior submissions.
      organization.connected_accounts.order(:id).each do |account|
        account.increment!(:readiness_revision)
        ConnectedAccounts::Manager.refresh_readiness!(account: account, actor: actor, request: request)
      end
      AuditLogger.record!(action: "organizer_tax_information.updated", auditable: record, actor: actor,
        organization: organization, metadata: { certification_version: record.certification_version }, request: request)
      record
    end
  rescue ActiveRecord::RecordInvalid => e
    raise TaxError, e.record.errors.full_messages.to_sentence
  rescue ConnectedAccounts::Manager::AccountError => e
    raise TaxError, e.message
  end
end
