# frozen_string_literal: true

class SeatAuditEvent < ApplicationRecord
  include AppendOnlyRecord

  belongs_to :event
  belongs_to :event_seat, optional: true
  belongs_to :seat_hold_session, optional: true
  belongs_to :ticket, optional: true
  belongs_to :actor_user, class_name: "User", optional: true

  validates :action, :occurred_at, presence: true
end
