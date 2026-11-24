# frozen_string_literal: true

class OrganizerFollow < ApplicationRecord
  normalizes :email_opted_in_address, with: ->(value) { value.strip.downcase }
  belongs_to :user
  belongs_to :organization
  validates :organization_id, uniqueness: { scope: :user_id }
end
