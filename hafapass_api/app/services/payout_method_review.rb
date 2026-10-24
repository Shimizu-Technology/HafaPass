# frozen_string_literal: true

# Manual payout approval is deliberately a single-administrator operation.
# Submission and decision remain separate immutable records in one transaction;
# provider-integrated accounts continue to use their detailed evidence workflow.
class PayoutMethodReview
  class ReviewError < StandardError; end
  class StateChanged < ReviewError; end

  TAX_FIELDS = %w[w9_on_file legal_name business_name masked_tin tax_classification certified_at certification_version].freeze

  def self.tax_snapshot(account)
    account.organization.organizer_tax_information&.safe_json&.slice(*TAX_FIELDS) || { "w9_on_file" => false }
  end

  def self.snapshot(account)
    {
      "version" => "manual-payout-v1", "organization_id" => account.organization_id,
      "organization_name" => account.organization.name, "provider" => account.provider,
      "country" => account.country, "currency" => account.currency,
      "payout_details" => account.safe_payout_details, "tax_information" => tax_snapshot(account),
      "readiness_state_digest" => account.readiness_state_digest
    }
  end

  def self.canonical(value)
    case value
    when Hash then value.stringify_keys.sort.to_h.transform_values { |item| canonical(item) }
    when Array then value.map { |item| canonical(item) }
    else value
    end
  end

  def self.digest(account)
    Digest::SHA256.hexdigest(canonical(snapshot(account)).to_json)
  end

  def self.account_json(account)
    organization = account.organization
    owner = organization.organization_memberships.find { |membership| membership.owner? && membership.status_active? }
    approval = account.active_payment_readiness_approval
    latest_decision = account.payment_readiness_reviews.where(review_kind: %w[manual_payout manual_change_request])
      .where(decision: [:approval, :rejection]).order(created_at: :desc, id: :desc).first
    change_request = latest_decision&.decision_rejection? && latest_decision.provider_state_digest == account.readiness_state_digest
    missing = account.manual_payout? ? account.manual_payout_missing : []
    status = if account.payout_ready?
      "approved"
    elsif change_request
      "changes_requested"
    elsif missing.any?
      "incomplete"
    else
      "waiting"
    end
    {
      id: account.id, provider: account.provider, organization_id: account.organization_id,
      organization_name: organization.name, owner_email: owner&.user&.email || organization.organizer_profile&.user&.email,
      status: account.status, payout_ready: account.payout_ready?, payout_details: account.safe_payout_details,
      tax_information: tax_snapshot(account),
      readiness_submission: review_json(account.pending_payment_readiness_submission),
      readiness_approval: review_json(account.latest_payment_readiness_approval),
      readiness_approval_active: approval.present?,
      payout_review: {
        manual: account.manual_payout?, status: status, missing: missing,
        can_approve: account.manual_payout? && missing.empty? && !account.payout_ready?,
        review_state_digest: digest(account), note: change_request ? latest_decision.reason : approval&.reason,
        review_by: approval&.expires_at&.to_date
      }
    }
  end

  def self.review_json(review)
    review&.attributes&.slice(
      "id", "actor_user_id", "decision", "evidence_reference", "evidence_digest", "provider_state_digest",
      "provider_approval_reference", "merchant_of_record", "fee_tax_schedule_reference", "liability_schedule_reference",
      "controls", "effective_at", "expires_at", "created_at"
    )
  end

  def self.queue
    accounts = ConnectedAccount.where(provider: ConnectedAccount::MANUAL_PROVIDERS)
      .includes(:payment_readiness_reviews, organization: [:organizer_tax_information, :organizer_profile, { organization_memberships: :user }])
      .order(updated_at: :desc, id: :desc).reject(&:payout_ready?)
    { count: accounts.size, items: accounts.map { |account| account_json(account) } }
  end

  def self.approve!(account:, actor:, controls:, expected_digest:, review_by: nil, note: nil, request: nil)
    review = nil
    account.organization.with_lock do
      account.with_lock do
        validate_state!(account, expected_digest)
        missing = account.manual_payout_missing
        raise ReviewError, missing.join(". ") if missing.any?
        raise ReviewError, "This payout method is already approved" if account.payout_ready?
        confirmed = controls.to_h.stringify_keys.slice(*PaymentReadinessReview::MANUAL_CONTROL_KEYS)
        unless PaymentReadinessReview::MANUAL_CONTROL_KEYS.all? { |key| ActiveModel::Type::Boolean.new.cast(confirmed[key]) == true }
          raise ReviewError, "Confirm each item before approving the payout method"
        end
        reason = safe_note!(note, account)
        expires_at = review_deadline(review_by)
        ConnectedAccounts::Manager.sync!(account: account, actor: actor, request: request,
          attributes: { charges_enabled: true, payouts_enabled: true, details_submitted: true, requirements_due: [] })
        submission = PaymentReadinessReviews::Manager.submit!(account: account, actor: actor, request: request,
          attributes: evidence(account, expires_at: expires_at, kind: "manual_payout", controls: confirmed))
        review = PaymentReadinessReviews::Manager.approve!(submission: submission, actor: actor,
          reason: reason, request: request)
        audit!(account, review, "payout_method.approved", actor, request)
        EmailService.send_payout_method_decision_async(review)
      end
    end
    review
  rescue ActiveRecord::RecordInvalid, ConnectedAccounts::Manager::AccountError, PaymentReadinessReviews::Manager::ReviewError => e
    raise ReviewError, e.respond_to?(:record) ? e.record.errors.full_messages.to_sentence : e.message
  end

  def self.request_changes!(account:, actor:, expected_digest:, note:, request: nil)
    review = nil
    account.organization.with_lock do
      account.with_lock do
        validate_state!(account, expected_digest)
        reason = safe_note!(note, account)
        raise ReviewError, "Write a note explaining what the organizer needs to change" if reason.blank?
        if (approval = account.active_payment_readiness_approval)
          PaymentReadinessReviews::Manager.revoke!(approval: approval, actor: actor, reason: reason, request: request)
        end
        submission = account.payment_readiness_reviews.create!(evidence(account,
          expires_at: 12.months.from_now, kind: "manual_change_request", controls: {}).merge(
            decision: :submission, actor_user: actor
          ))
        PaymentReadinessReviews::Manager.send(:record!, submission, "payment_readiness.submitted", actor, request)
        review = PaymentReadinessReviews::Manager.reject!(submission: submission, actor: actor, reason: reason, request: request)
        audit!(account, review, "payout_method.changes_requested", actor, request)
        EmailService.send_payout_method_decision_async(review)
      end
    end
    review
  rescue ActiveRecord::RecordInvalid, PaymentReadinessReviews::Manager::ReviewError => e
    raise ReviewError, e.respond_to?(:record) ? e.record.errors.full_messages.to_sentence : e.message
  end

  def self.validate_state!(account, expected_digest)
    raise ReviewError, "Use the detailed evidence review for this provider" unless account.manual_payout?
    unless expected_digest.present? && ActiveSupport::SecurityUtils.secure_compare(expected_digest.to_s, digest(account))
      raise StateChanged, "Payout or W-9 details changed. Refresh and review the latest details."
    end
  end

  def self.safe_note!(note, account)
    text = note.to_s.strip
    raise ReviewError, "Keep the note to 500 characters" if text.length > 500
    contains_account = account.bank_account_number.present? && text.gsub(/\D/, "").include?(account.bank_account_number)
    numeric_sequence = /(?<!\d)(?:\d[\s.\-–—\/,]*){8,34}(?!\d)/
    account_reference = /\b(?:account|acct|bank|routing|tin)\s*[:#=]?\s*(?:\d[\s.\-–—\/,]*){4,34}/i
    if contains_account || !BackupWithholding.safe_text?(text) || text.match?(numeric_sequence) || text.match?(account_reference)
      raise ReviewError, "Leave tax IDs and full bank account numbers out of the note"
    end

    text.presence
  end

  def self.review_deadline(value)
    date = value.present? ? Date.iso8601(value.to_s) : Date.current.advance(months: 12)
    raise ReviewError, "Choose a review-by date after today" unless date > Date.current

    date.in_time_zone.end_of_day
  rescue Date::Error
    raise ReviewError, "Choose a valid review-by date"
  end

  def self.evidence(account, expires_at:, kind:, controls:)
    reviewed = canonical(snapshot(account))
    digest = Digest::SHA256.hexdigest(reviewed.to_json)
    reference = "hafapass://payout-methods/#{account.id}/snapshots/#{digest}"
    {
      evidence_reference: reference, evidence_digest: digest, provider_state_digest: account.readiness_state_digest,
      provider_approval_reference: "hafapass-manual-payout-v1", merchant_of_record: "organizer",
      fee_tax_schedule_reference: "hafapass-organizer-agreement", liability_schedule_reference: "hafapass-limited-collection-agent",
      controls: controls.transform_values { |value| ActiveModel::Type::Boolean.new.cast(value) },
      effective_at: Time.current, expires_at: expires_at, review_kind: kind, reviewed_snapshot: reviewed
    }
  end

  def self.audit!(account, review, action, actor, request)
    AuditLogger.record!(action: action, auditable: review, organization: account.organization, actor: actor,
      after_data: { provider: account.provider, organization_name: account.organization.name, review_by: review.expires_at.to_date },
      request: request)
  end

  private_class_method :validate_state!, :safe_note!, :review_deadline, :evidence, :audit!
end
