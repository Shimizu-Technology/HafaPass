# frozen_string_literal: true

class OrganizationMembership < ApplicationRecord
  belongs_to :organization
  belongs_to :user, optional: true
  belongs_to :invited_by_user, class_name: "User", optional: true
  has_many :message_deliveries, dependent: :restrict_with_error

  enum :role, { owner: 0, manager: 1, finance: 2, marketer: 3, box_office: 4, scanner: 5 }
  enum :status, { invited: 0, active: 1, revoked: 2 }, prefix: true

  validates :user_id, uniqueness: { scope: :organization_id }, allow_nil: true
  validates :invited_email, format: { with: URI::MailTo::EMAIL_REGEXP }, allow_blank: true
  validate :active_membership_has_acceptance
  validate :user_or_invited_email_present
  validate :pending_event_assignments_shape
  after_update :audit_acceptance

  scope :effective, ->(at = Time.current) { status_active.where("expires_at IS NULL OR expires_at > ?", at) }

  # expires_at is when an owner chose to end this person's access. It never
  # carries the invitation link's lifetime (see invitation_expires_at).
  def effective?(at: Time.current)
    status_active? && (expires_at.nil? || expires_at > at)
  end

  # pending / accepted / expired / revoked, for people reading a team list.
  def invitation_status(at: Time.current)
    return "revoked" if status_revoked?
    return effective?(at: at) ? "accepted" : "access_ended" if status_active?
    return "expired" if invitation_expires_at.nil? || invitation_expires_at <= at

    "pending"
  end

  def invitation_open?(at: Time.current)
    invitation_status(at: at) == "pending"
  end

  def pending_event_ids
    Array(pending_event_assignments).filter_map { |entry| entry["event_id"]&.to_i }
  end

  private

  def audit_acceptance
    return unless saved_change_to_status? && status_active? && accepted_at

    AuditLogger.record!(action: "organization.invitation_accepted", auditable: self,
      actor: AuditContext.actor || user, organization: organization,
      before_data: saved_changes.slice("role", "status", "user_id", "accepted_at").transform_values(&:first),
      after_data: { target_user_id: user_id, target_name: [user&.first_name, user&.last_name].compact.join(" "),
        role: role, status: status, accepted_at: accepted_at })
  end

  def active_membership_has_acceptance
    if status_active? && (accepted_at.blank? || user_id.blank?)
      errors.add(:accepted_at, "and a user are required for an active membership")
    end
  end

  def pending_event_assignments_shape
    entries = pending_event_assignments
    valid = entries.is_a?(Array) && entries.all? do |entry|
      entry.is_a?(Hash) && entry["event_id"].present? && EventStaffAssignment.roles.key?(entry["role"].to_s)
    end
    errors.add(:pending_event_assignments, "are invalid") unless valid
  end

  def user_or_invited_email_present
    errors.add(:base, "A user or invited email is required") if user_id.blank? && invited_email.blank?
  end
end
