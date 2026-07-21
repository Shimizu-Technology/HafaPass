# frozen_string_literal: true

class LivePilotMetricSnapshot < ApplicationRecord
  include AppendOnlyRecord

  belongs_to :live_pilot_run
  belongs_to :event
  belongs_to :recorded_by_user, class_name: "User"

  validates :evidence_reference, :evidence_digest, :observed_at, presence: true
  validates :evidence_digest, format: { with: /\A[0-9a-f]{64}\z/ }
  validate :relationships_match

  def pause_required?
    breached_thresholds.to_h.any?
  end

  private

  def relationships_match
    errors.add(:event, "must match the pilot run") if live_pilot_run && live_pilot_run.event_id != event_id
  end
end
