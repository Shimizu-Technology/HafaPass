# frozen_string_literal: true

class OrganizationMembership < ApplicationRecord
  belongs_to :organization
  belongs_to :user, optional: true
  belongs_to :invited_by_user, class_name: "User", optional: true

  enum :role, { owner: 0, manager: 1, finance: 2, marketer: 3, box_office: 4, scanner: 5 }
  enum :status, { invited: 0, active: 1, revoked: 2 }, prefix: true

  validates :user_id, uniqueness: { scope: :organization_id }, allow_nil: true
  validates :invited_email, format: { with: URI::MailTo::EMAIL_REGEXP }, allow_blank: true
  validate :active_membership_has_acceptance
  validate :user_or_invited_email_present

  scope :effective, ->(at = Time.current) { status_active.where("expires_at IS NULL OR expires_at > ?", at) }

  def effective?(at: Time.current)
    status_active? && (expires_at.nil? || expires_at > at)
  end

  private

  def active_membership_has_acceptance
    if status_active? && (accepted_at.blank? || user_id.blank?)
      errors.add(:accepted_at, "and a user are required for an active membership")
    end
  end

  def user_or_invited_email_present
    errors.add(:base, "A user or invited email is required") if user_id.blank? && invited_email.blank?
  end
end
