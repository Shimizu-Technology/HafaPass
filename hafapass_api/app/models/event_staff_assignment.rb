# frozen_string_literal: true

class EventStaffAssignment < ApplicationRecord
  belongs_to :organization
  belongs_to :event
  belongs_to :user
  belongs_to :assigned_by_user, class_name: "User", optional: true

  enum :role, { box_office: 0, scanner: 1, manager: 2 }
  enum :status, { active: 0, revoked: 1 }, prefix: true

  validates :role, uniqueness: { scope: [:event_id, :user_id] }
  validate :event_matches_organization

  scope :effective, ->(at = Time.current) { status_active.where("expires_at IS NULL OR expires_at > ?", at) }

  def effective?(at: Time.current)
    status_active? && (expires_at.nil? || expires_at > at)
  end

  private

  def event_matches_organization
    return if event.nil? || organization.nil? || event.organization_id == organization_id

    errors.add(:event, "must belong to the same organization")
  end
end
