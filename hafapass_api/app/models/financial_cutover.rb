# frozen_string_literal: true

# Append-only release boundaries (docs/design/never-fulfilled-captures.md §4.1):
# a1_capture_recording and a1_return_recording bound every pre-A1 timing
# fallback, so later evidence cannot move a fact between periods.
class FinancialCutover < ApplicationRecord
  def self.recorded_at(key)
    find_by(key: key)&.recorded_at
  end

  def readonly?
    persisted? || super
  end
end
