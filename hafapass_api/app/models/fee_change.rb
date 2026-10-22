# frozen_string_literal: true

class FeeChange < ApplicationRecord
  TERMS = PolicyRegistry::MATERIAL_SETTINGS.freeze
  belongs_to :created_by, class_name: "User"
  has_many :notices, class_name: "FeeChangeNotice", dependent: :restrict_with_error

  validates :effective_at, presence: true
  validates :old_terms, :new_terms, presence: true

  scope :pending, -> { where(activated_at: nil) }

  def self.affected_events(at: Time.current)
    # Open sales are published events; future drafts are included because their
    # organizer may price or announce them before the effective date.
    Event.where.not(status: [:cancelled, :archived, :completed])
      .where("status = :published OR starts_at > :at", published: Event.statuses.fetch("published"), at: at)
  end

  def self.affected_organizer_count(at: Time.current)
    affected_events(at: at).distinct.count(:organization_id)
  end

  def self.terms_for(settings)
    {
      "service_fee_percent" => settings.service_fee_percent.to_d.to_s,
      "service_fee_flat_cents" => settings.service_fee_flat_cents.to_i,
      "processing_fee_bearer" => settings.processing_fee_bearer.to_s,
      "payout_schedule_text" => settings.payout_schedule_text.to_s
    }
  end

  # This runs on the first settings read after the effective instant, so no
  # separately scheduled worker is needed for checkout to switch on time.
  def self.activate_due!(settings)
    pending.where("effective_at <= ?", Time.current).order(:effective_at, :id).each do |change|
      change.with_lock do
        next if change.activated_at?

        settings.lock!
        unless terms_for(settings) == change.old_terms
          raise "Scheduled fee terms no longer match the active terms"
        end
        settings.update!(change.new_terms)
        change.update!(activated_at: Time.current)
        AuditLogger.record!(action: "site_settings.fee_terms_activated", auditable: settings,
          before_data: change.old_terms, after_data: change.new_terms,
          metadata: { fee_change_id: change.id, effective_at: change.effective_at.iso8601 })
      end
    end
  end

  def self.schedule!(settings:, attributes:, effective_at:, actor:, request: nil)
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

      change = create!(created_by: actor, old_terms: old_terms, new_terms: new_terms, effective_at: effective_at)
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
          affected_organizers: change.notices.distinct.count(:organization_id) }, request: request)
    end
    ActiveRecord.after_all_transactions_commit do
      change.notices.find_each do |notice|
        EmailService.send_fee_change_notice_async(notice)
      rescue StandardError => e
        Rails.logger.error("[FeeChangeNotice] Unable to queue notice=#{notice.id}: #{e.class}")
      end
    end
    change
  end
end
