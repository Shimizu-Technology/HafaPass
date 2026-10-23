# frozen_string_literal: true

class CommunicationCampaign < ApplicationRecord
  SEGMENT_TYPES = %w[all_attendees checked_in not_checked_in ticket_type].freeze

  belongs_to :event
  belongs_to :created_by_user, class_name: "User"
  has_many :message_deliveries, dependent: :restrict_with_error

  enum :status, { draft: 0, scheduled: 1, sending: 2, sent: 3, cancelled: 4, failed: 5 }

  validates :name, :subject, :body, presence: true
  validates :subject, length: { maximum: 240 }
  validates :body, length: { maximum: 20_000 }
  validates :recipient_count, numericality: { only_integer: true, greater_than_or_equal_to: 0 }
  validate :valid_segment
  after_create :audit_creation
  after_update :audit_changes
  after_destroy :audit_deletion

  def segment_type
    segment["type"].to_s
  end

  private

  AUDIT_FIELDS = %w[name status scheduled_at segment recipient_count].freeze

  def audit_creation
    audit_campaign("campaign.created", {}, attributes.slice(*AUDIT_FIELDS))
  end

  def audit_deletion
    audit_campaign("campaign.deleted", attributes.slice(*AUDIT_FIELDS), {})
  end

  def audit_changes
    changes = saved_changes.slice(*AUDIT_FIELDS)
    # Body/subject are free text and may contain pasted contact data. Record
    # that content changed, without copying a mailing into the audit trail.
    content_changed = (saved_changes.keys & %w[subject body]).any?
    return if changes.empty? && !content_changed

    action = if saved_change_to_status? && scheduled?
      "campaign.scheduled"
    elsif saved_change_to_status? && sending?
      "campaign.send_requested"
    elsif saved_change_to_status? && sent?
      "campaign.send_completed"
    elsif saved_change_to_status? && failed?
      "campaign.send_failed"
    else
      "campaign.updated"
    end
    audit_campaign(action, changes.transform_values(&:first), changes.transform_values(&:last),
      content_changed: content_changed)
  end

  def audit_campaign(action, before, after, content_changed: false)
    AuditLogger.record!(action: action, auditable: self, event: event,
      before_data: before, after_data: after,
      metadata: { content_changed: content_changed, delivery_phase: "queueing" },
      outcome: action == "campaign.send_requested" ? "requested" : (action == "campaign.send_failed" ? "failed" : "succeeded"))
  end

  def valid_segment
    errors.add(:segment, "type is invalid") unless SEGMENT_TYPES.include?(segment_type)
    if segment_type == "ticket_type" && segment["ticket_type_id"].blank?
      errors.add(:segment, "ticket type is required")
    end
  end
end
