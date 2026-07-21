# frozen_string_literal: true

class LivePilotRunAction < ApplicationRecord
  include AppendOnlyRecord

  belongs_to :live_pilot_run
  belongs_to :event
  belongs_to :actor_user, class_name: "User", optional: true

  enum :kind, { started: 0, paused: 1, resumed: 2, completed: 3, aborted: 4 }, prefix: true

  validates :occurred_at, presence: true
  validate :relationships_match

  private

  def relationships_match
    errors.add(:event, "must match the pilot run") if live_pilot_run && live_pilot_run.event_id != event_id
  end
end
