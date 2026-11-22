# frozen_string_literal: true

class EventSeriesMembership < ApplicationRecord
  belongs_to :event_series
  belongs_to :event

  enum :role, {
    regular_night: 0,
    championship_night: 1,
    pass_sale: 2,
    registration: 3,
    other: 4
  }

  validates :event_id, uniqueness: { scope: :event_series_id, message: "is already in this event series" }
  validates :position, numericality: { only_integer: true, greater_than_or_equal_to: 0 }
  validate :event_belongs_to_series_organization

  after_create :audit_event_added
  after_destroy :audit_event_removed

  private

  def event_belongs_to_series_organization
    return unless event && event_series
    return if event.organization_id == event_series.organization_id

    errors.add(:event, "must belong to the same organization as the event series")
  end

  def audit_event_added
    AuditLogger.record!(
      action: "event_series.event_added",
      auditable: event_series,
      event: event,
      organization: event_series.organization,
      after_data: { role: role, position: position },
      metadata: { event_series_id: event_series_id, event_id: event_id, role: role, position: position }
    )
  end

  def audit_event_removed
    return if event_series.destroyed?

    AuditLogger.record!(
      action: "event_series.event_removed",
      auditable: event_series,
      event: event,
      organization: event_series.organization,
      before_data: { role: role, position: position },
      metadata: { event_series_id: event_series_id, event_id: event_id, role: role, position: position }
    )
  end
end
