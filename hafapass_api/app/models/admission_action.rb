# frozen_string_literal: true

class AdmissionAction < ApplicationRecord
  belongs_to :organization
  belongs_to :event
  belongs_to :ticket, optional: true
  belongs_to :scanner_device, optional: true
  belongs_to :actor_user, class_name: "User", optional: true
  belongs_to :reverses_action, class_name: "AdmissionAction", optional: true
  has_one :reversal_action, class_name: "AdmissionAction", foreign_key: :reverses_action_id,
    dependent: :restrict_with_error, inverse_of: :reverses_action

  enum :kind, { admit: 0, reverse: 1 }, prefix: true
  enum :source, { online: 0, offline: 1, manual: 2 }, prefix: true
  enum :result, { accepted: 0, rejected: 1, conflict: 2 }, prefix: true

  validates :action_uuid, :reason_code, :occurred_at, :received_at, presence: true
  validates :action_uuid, uniqueness: true
  validates :action_uuid, length: { maximum: 128 }
  validates :sequence, numericality: { only_integer: true, greater_than: 0 }, allow_nil: true
  validates :manifest_version, numericality: { only_integer: true, greater_than: 0 }, allow_nil: true
  validates :reverses_action_id, uniqueness: true, allow_nil: true
  validate :relationships_share_event
  validate :device_sequence_pair
  validate :reversal_shape

  attr_readonly :organization_id, :event_id, :ticket_id, :scanner_device_id, :actor_user_id,
    :reverses_action_id, :action_uuid, :kind, :source, :result, :reason_code, :credential_hash,
    :manifest_version, :sequence, :occurred_at, :received_at, :attendee_snapshot, :metadata

  before_update :prevent_mutation
  before_destroy :prevent_mutation

  private

  def relationships_share_event
    relationship_event_ids = [ticket&.event_id, scanner_device&.event_id, reverses_action&.event_id].compact.uniq
    errors.add(:base, "Admission relationships must share an event") if relationship_event_ids.any? && relationship_event_ids != [event_id]
    errors.add(:event, "must belong to the same organization") if event && event.organization_id != organization_id
  end

  def device_sequence_pair
    return if scanner_device_id.present? == sequence.present?

    errors.add(:sequence, "must be present exactly when a scanner device is present")
  end

  def reversal_shape
    if kind_reverse? && reverses_action.nil?
      errors.add(:reverses_action, "is required for a reversal")
    elsif kind_admit? && reverses_action.present?
      errors.add(:reverses_action, "is only allowed for a reversal")
    elsif reverses_action && (!reverses_action.kind_admit? || !reverses_action.result_accepted?)
      errors.add(:reverses_action, "must be an accepted admission")
    end
  end

  def prevent_mutation
    errors.add(:base, "Admission actions are append-only")
    throw(:abort)
  end
end
