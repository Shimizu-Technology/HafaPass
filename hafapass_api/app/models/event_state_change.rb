# frozen_string_literal: true

class EventStateChange < ApplicationRecord
  belongs_to :event
  belongs_to :actor_user, class_name: "User"

  validates :action, :from_status, :to_status, :occurred_at, presence: true

  after_create :promote_to_audit_log!

  before_update :prevent_mutation
  before_destroy :prevent_mutation

  private

  def promote_to_audit_log!
    suffix = {
      "publish" => "published", "postpone" => "postponed", "resume" => "resumed",
      "cancel" => "cancelled", "complete" => "completed", "archive" => "archived"
    }.fetch(action)
    AuditLogger.record!(action: "event.#{suffix}", auditable: event, event: event, actor: actor_user,
      source: AuditContext.current.source.presence || "user", outcome: "succeeded",
      before_data: { status: from_status }, after_data: { status: to_status },
      metadata: { event_state_change_id: id }, deduplication_key: "event_state_change/#{id}")
  end

  def prevent_mutation
    errors.add(:base, "Event state history is append-only")
    throw :abort
  end
end
