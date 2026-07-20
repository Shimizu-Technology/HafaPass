# frozen_string_literal: true

class AdmissionManifest < ApplicationRecord
  belongs_to :organization
  belongs_to :event
  belongs_to :generated_by_user, class_name: "User", optional: true

  validates :version, numericality: { only_integer: true, greater_than: 0 }, uniqueness: { scope: :event_id }
  validates :source_digest, :digest, :signature, :key_id, :algorithm, :generated_at, :expires_at, presence: true
  validates :digest, uniqueness: true
  validates :ticket_count, numericality: { only_integer: true, greater_than_or_equal_to: 0 }
  validate :event_matches_organization
  validate :expiration_follows_generation

  attr_readonly :organization_id, :event_id, :generated_by_user_id, :version, :source_digest, :digest,
    :signature, :key_id, :algorithm, :payload, :ticket_count, :generated_at, :expires_at

  before_update :prevent_mutation
  before_destroy :prevent_mutation

  def expired?(at: Time.current)
    expires_at <= at
  end

  private

  def event_matches_organization
    return if event.nil? || event.organization_id == organization_id

    errors.add(:event, "must belong to the same organization")
  end

  def expiration_follows_generation
    return if generated_at.nil? || expires_at.nil? || expires_at > generated_at

    errors.add(:expires_at, "must be after generation")
  end

  def prevent_mutation
    errors.add(:base, "Admission manifests are immutable")
    throw(:abort)
  end
end
