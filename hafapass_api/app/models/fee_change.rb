# frozen_string_literal: true

class FeeChange < ApplicationRecord
  TERMS = PolicyRegistry::MATERIAL_SETTINGS.freeze
  belongs_to :created_by, class_name: "User"
  belongs_to :preapproval, class_name: "PlatformCapabilityReview", optional: true
  has_many :notices, class_name: "FeeChangeNotice", dependent: :restrict_with_error

  validates :effective_at, presence: true
  validates :old_terms, :new_terms, presence: true

  scope :pending, -> { where(activated_at: nil, blocked_at: nil) }

  def self.affected_events(at: Time.current)
    # Open sales are published events; future drafts are included because their
    # organizer may price or announce them before the effective date.
    Event.where.not(status: [:cancelled, :archived, :completed])
      .where("status = :published OR starts_at > :at", published: Event.statuses.fetch("published"), at: at)
  end

  def self.affected_organizer_count(at: Time.current)
    affected_events(at: at).distinct.count(:organization_id)
  end

  def self.notice_preview(at: Time.current)
    organizations = affected_events(at: at).distinct.pluck(:organization_id)
    owners = OrganizationMembership.where(organization_id: organizations, role: :owner)
      .effective.includes(:user).select { |membership| membership.user&.email.present? }
    reached = owners.map(&:organization_id).uniq
    unreachable_ids = organizations - reached
    unreachable = Organization.where(id: unreachable_ids).order(:name).pluck(:id, :name)
      .map { |id, name| { id: id, name: name } }
    { affected_organizer_count: organizations.size, owner_email_count: owners.size,
      unreachable_organization_ids: unreachable_ids, unreachable_organizations: unreachable }
  end

  def self.terms_for(settings)
    {
      "service_fee_percent" => settings.service_fee_percent.to_d.to_s,
      "service_fee_flat_cents" => settings.service_fee_flat_cents.to_i,
      "processing_fee_bearer" => settings.processing_fee_bearer.to_s,
      "payout_schedule_text" => settings.payout_schedule_text.to_s
    }
  end

  def self.proposed_registry_digest(settings:, attributes:)
    proposed = settings.dup
    proposed.assign_attributes(attributes)
    proposed.validate!
    PolicyRegistry.registry_digest(material_terms: terms_for(proposed))
  end

  def self.activate_due!(settings)
    pending.where("effective_at <= ?", Time.current).order(:effective_at, :id).each do |change|
      change.with_lock do
        next if change.activated_at? || change.blocked_at?

        settings.lock!
        unless terms_for(settings) == change.old_terms
          change.block!(settings, "Active fee terms changed since scheduling")
          next
        end
        expected_registry = PolicyRegistry.registry_digest(material_terms: change.new_terms)
        expected_configuration = PlatformCapabilities.configuration_digest("policy_register", material_terms: change.new_terms)
        unless change.preapproval&.decision_approval? && change.preapproved_registry_digest == expected_registry &&
            change.preapproval.configuration_digest == expected_configuration && change.preapproval.effective_at <= Time.current &&
            change.preapproval.expires_at > Time.current && !change.preapproval.revoked?
          change.block!(settings, "Future policy approval no longer matches the scheduled terms or policy text")
          next
        end
        settings.update!(change.new_terms)
        change.update!(activated_at: Time.current)
        AuditLogger.record!(action: "site_settings.fee_terms_activated", auditable: settings,
          before_data: change.old_terms, after_data: change.new_terms,
          metadata: { fee_change_id: change.id, effective_at: change.effective_at.iso8601 })
      end
    end
  end

  def block!(settings, reason)
    update!(blocked_at: Time.current, activation_error: reason)
    AuditLogger.record!(action: "site_settings.fee_terms_activation_blocked", auditable: settings,
      metadata: { fee_change_id: id, reason: reason })
    Rails.logger.error("[FeeChange] Activation blocked id=#{id}: #{reason}")
    begin
      Sentry.capture_message("Scheduled fee change #{id} blocked: #{reason}")
    rescue StandardError => e
      Rails.logger.error("[FeeChange] Unable to report blocked activation id=#{id}: #{e.class}")
    end
  end

  def self.schedule!(settings:, attributes:, effective_at:, actor:, request: nil, future_terms_approved: false,
    approved_registry_digest: nil)
    change = nil
    settings.with_lock do
      raise ArgumentError, "A fee change is already scheduled" if pending.exists?
      minimum = settings.fee_notice_days.days.from_now
      raise ArgumentError, "Effective date must be at least #{settings.fee_notice_days} days ahead" if effective_at < minimum

      old_terms = terms_for(settings)
      proposed = settings.dup
      proposed.assign_attributes(attributes)
      proposed.validate!
      new_terms = terms_for(proposed)
      raise ArgumentError, "Fee terms have not changed" if new_terms == old_terms
      current_approval = PlatformCapabilities.active_approval("policy_register")
      raise ArgumentError, "Approve the current policy register before scheduling fee changes" unless current_approval
      if current_approval.expires_at < effective_at
        raise ArgumentError, "Current policy approval expires before the fee change; renew it first"
      end
      raise ArgumentError, "Approve the exact future fee and policy terms before scheduling" unless future_terms_approved
      blockers = PolicyRegistry.approval_blockers
      raise ArgumentError, "Policy text has technical problems: #{blockers.join('; ')}" if blockers.any?
      digest = PolicyRegistry.registry_digest(material_terms: new_terms)
      unless approved_registry_digest.present? &&
          ActiveSupport::SecurityUtils.secure_compare(approved_registry_digest.to_s, digest)
        raise ArgumentError, "Future policy terms changed; preview them again before approving"
      end
      configuration_digest = PlatformCapabilities.configuration_digest("policy_register", material_terms: new_terms)
      reference = "scheduled-fee-change/#{effective_at.utc.iso8601(6)}/#{SecureRandom.uuid}"
      snapshot = { capability: "policy_register", evidence_reference: reference,
        evidence_digest: Digest::SHA256.hexdigest(JSON.generate([reference, actor.id, configuration_digest])),
        configuration_digest: configuration_digest,
        controls: current_approval.controls,
        effective_at: effective_at, expires_at: effective_at + PlatformCapabilityReviews::Manager::QUICK_APPROVAL_TERM,
        actor_user: actor }
      submission = PlatformCapabilityReview.create!(snapshot.merge(decision: :submission))
      approval = PlatformCapabilityReview.create!(snapshot.merge(decision: :approval, parent_review: submission))

      change = create!(created_by: actor, old_terms: old_terms, new_terms: new_terms, effective_at: effective_at,
        preapproval: approval, preapproved_registry_digest: digest)
      affected_events.includes(organization: { organization_memberships: :user }).order(:id).each do |event|
        event.organization.organization_memberships.each do |membership|
          next unless membership.owner? && membership.effective? && membership.user&.email.present?
          next if change.notices.exists?(organization_id: event.organization_id, owner_id: membership.user_id)

          change.notices.create!(organization: event.organization, owner: membership.user,
            recipient_email: membership.user.email, buyer_fee_percent: event.buyer_fee_percent,
            fee_policy: event.fee_policy, event_id: event.id)
        end
      end
      AuditLogger.record!(action: "site_settings.fee_terms_scheduled", auditable: settings, actor: actor,
        before_data: old_terms, after_data: new_terms,
        metadata: { fee_change_id: change.id, effective_at: effective_at.iso8601,
          affected_organizers: affected_organizer_count, owners_emailed: change.notices.count,
          preapproval_id: approval.id, registry_digest: digest }, request: request)
    end
    ActiveRecord.after_all_transactions_commit do
      begin
        ActivateFeeChangeJob.set(wait_until: change.effective_at).perform_later(change.id)
      rescue StandardError => e
        Rails.logger.error("[FeeChange] Unable to queue activation=#{change.id}: #{e.class}")
        Sentry.capture_exception(e)
      end
      change.notices.find_each do |notice|
        EmailService.send_fee_change_notice_async(notice)
      rescue StandardError => e
        Rails.logger.error("[FeeChangeNotice] Unable to queue notice=#{notice.id}: #{e.class}")
      end
    end
    change
  end
end
