# frozen_string_literal: true

class ScannerDevice < ApplicationRecord
  belongs_to :organization
  belongs_to :event
  belongs_to :user
  has_many :admission_actions, dependent: :restrict_with_error

  enum :status, { active: 0, revoked: 1 }, prefix: true

  validates :identifier, :name, :authorization_expires_at, presence: true
  validates :identifier, uniqueness: { scope: :event_id }
  validates :identifier, length: { maximum: 128 }
  validates :name, length: { maximum: 100 }
  validates :last_manifest_version, :last_sequence,
    numericality: { only_integer: true, greater_than_or_equal_to: 0 }
  validate :relationships_share_organization

  def effective?(at: Time.current)
    status_active? && authorization_expires_at > at && (revoked_at.nil? || revoked_at > at)
  end

  def revoke!(at: Time.current)
    update!(status: :revoked, revoked_at: at)
  end

  private

  def relationships_share_organization
    return if event.nil? || event.organization_id == organization_id

    errors.add(:event, "must belong to the same organization")
  end
end
