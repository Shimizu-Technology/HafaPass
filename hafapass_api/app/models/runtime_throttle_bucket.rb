# frozen_string_literal: true

class RuntimeThrottleBucket < ApplicationRecord
  self.primary_key = :key_hash
end
