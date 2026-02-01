# frozen_string_literal: true

class PromoCode < ApplicationRecord
  belongs_to :event
  has_many :orders

  DISCOUNT_TYPES = %w[percentage fixed].freeze

  validates :code, presence: true
  validates :code, uniqueness: { scope: :event_id, case_sensitive: false }
  validates :discount_type, inclusion: { in: DISCOUNT_TYPES }
  validates :discount_value, presence: true, numericality: { greater_than: 0 }
  validates :discount_value, numericality: { less_than_or_equal_to: 100 }, if: :percentage?

  before_validation :normalize_code

  scope :active_codes, -> {
    where(active: true)
      .where("starts_at IS NULL OR starts_at <= ?", Time.current)
      .where("expires_at IS NULL OR expires_at > ?", Time.current)
  }

  def percentage?
    discount_type == "percentage"
  end

  def fixed?
    discount_type == "fixed"
  end

  def usable?
    active? &&
      (starts_at.nil? || starts_at <= Time.current) &&
      (expires_at.nil? || expires_at > Time.current) &&
      (max_uses.nil? || current_uses < max_uses)
  end

  # Calculate discount in cents for a given subtotal
  def calculate_discount(subtotal_cents)
    return 0 unless usable?

    if percentage?
      (subtotal_cents * discount_value / 100.0).round
    else
      [discount_value, subtotal_cents].min  # Can't discount more than subtotal
    end
  end

  def increment_usage!
    increment!(:current_uses)
  end

  private

  def normalize_code
    self.code = code&.strip&.upcase
  end
end
