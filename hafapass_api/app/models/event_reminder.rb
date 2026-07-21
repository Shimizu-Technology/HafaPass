# frozen_string_literal: true

class EventReminder < ApplicationRecord
  belongs_to :user
  belongs_to :event
  enum :status, { pending: 0, sent: 1, cancelled: 2 }
  validates :event_id, uniqueness: { scope: :user_id }
  validates :remind_at, presence: true
end
