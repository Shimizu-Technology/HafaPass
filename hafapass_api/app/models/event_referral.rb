# frozen_string_literal: true

class EventReferral < ApplicationRecord
  belongs_to :user
  belongs_to :event
  has_many :marketplace_funnel_events, dependent: :restrict_with_error
  has_many :acquisition_attributions, dependent: :restrict_with_error
  validates :code, uniqueness: true
  validates :event_id, uniqueness: { scope: :user_id }
  before_validation :assign_code, on: :create

  private

  def assign_code
    self.code ||= loop do
      candidate = SecureRandom.alphanumeric(10).upcase
      break candidate unless EventReferral.exists?(code: candidate)
    end
  end
end
