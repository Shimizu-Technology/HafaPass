# frozen_string_literal: true

class OrganizerFollow < ApplicationRecord
  belongs_to :user
  belongs_to :organization
  validates :organization_id, uniqueness: { scope: :user_id }
end
