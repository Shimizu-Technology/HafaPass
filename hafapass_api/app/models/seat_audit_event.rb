# frozen_string_literal: true

class SeatAuditEvent < ApplicationRecord
  include AppendOnlyRecord

  belongs_to :event
  belongs_to :event_seat, optional: true
  belongs_to :seat_hold_session, optional: true
  belongs_to :ticket, optional: true
  belongs_to :actor_user, class_name: "User", optional: true

  validates :action, :occurred_at, presence: true
  after_create :promote_operational_action

  # Buyer hold churn remains in the detailed seat ledger. Changes made while
  # operating an event also belong in the organization's central history.
  CENTRAL_ACTIONS = %w[seating.organizer_sales_suspended seating.organizer_sales_resumed seating.configuration_activated seat.status_changed
    accessible_seat.released seat.exchanged seat.released_from_ticket].freeze

  private

  def promote_operational_action
    return unless CENTRAL_ACTIONS.include?(action)

    AuditLogger.record!(action: action, auditable: event_seat || ticket || event,
      organization: event.organization, event: event, actor: actor_user,
      before_data: central_before_data,
      after_data: central_after_data,
      metadata: metadata.merge("event_seat_id" => event_seat_id, "ticket_id" => ticket_id,
        "seat_audit_event_id" => id).compact, deduplication_key: "seat-audit/#{id}")
  end

  def central_before_data
    return { operational_status: event_seat.operational_status_before_last_save } if action == "seat.status_changed"
    return {} unless %w[seating.organizer_sales_suspended seating.organizer_sales_resumed].include?(action)

    { organizer_sales_suspended_at: event.organizer_sales_suspended_at_before_last_save }
  end

  def central_after_data
    return { operational_status: event_seat.operational_status } if action == "seat.status_changed"
    return {} unless %w[seating.organizer_sales_suspended seating.organizer_sales_resumed].include?(action)

    { organizer_sales_suspended_at: event.organizer_sales_suspended_at }
  end
end
