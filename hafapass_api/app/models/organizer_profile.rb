class OrganizerProfile < ApplicationRecord
  belongs_to :user
  has_many :events, dependent: :destroy

  validates :business_name, presence: true
  validates :user_id, uniqueness: true
end
