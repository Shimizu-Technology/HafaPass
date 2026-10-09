# frozen_string_literal: true

# A durable destination makes a lost completion response safe to retry. A
# receipt is committed before storage work; its destination survives timeouts.
class ImageUploadReceipt < ApplicationRecord
  belongs_to :user
  belongs_to :organization
  belongs_to :event, optional: true

  validates :source_key, :final_key, presence: true
end
