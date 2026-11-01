# frozen_string_literal: true

# Per-signal memory for OperationalAlertJob (see that job).
class RuntimeAlertState < ApplicationRecord
  self.primary_key = :signal
end
