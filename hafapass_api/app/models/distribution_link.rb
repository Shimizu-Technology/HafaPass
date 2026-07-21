# frozen_string_literal: true

class DistributionLink < ApplicationRecord
  belongs_to :distribution_partner
  belongs_to :event
  belongs_to :created_by_user, class_name: "User"
  has_many :marketplace_funnel_events, dependent: :restrict_with_error
  has_many :acquisition_attributions, dependent: :restrict_with_error

  validates :code, :campaign, presence: true
  validates :code, uniqueness: true
  validates :campaign, format: { with: /\A[a-zA-Z0-9._-]{1,100}\z/ }
  before_validation :assign_code, on: :create

  scope :available, ->(at = Time.current) {
    joins(:distribution_partner).where(active: true, distribution_partners: { active: true })
      .where("distribution_links.expires_at IS NULL OR distribution_links.expires_at > ?", at)
  }

  private

  def assign_code
    self.code ||= loop do
      candidate = SecureRandom.alphanumeric(10).upcase
      break candidate unless DistributionLink.exists?(code: candidate)
    end
  end
end
