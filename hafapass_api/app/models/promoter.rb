# frozen_string_literal: true

class Promoter < ApplicationRecord
  belongs_to :event
  has_many :referral_attributions, dependent: :restrict_with_error
  has_many :promoter_commission_entries, dependent: :restrict_with_error

  validates :name, :code, presence: true
  validates :code, uniqueness: { scope: :event_id }, format: { with: /\A[A-Z0-9_-]+\z/ }
  validates :email, format: { with: URI::MailTo::EMAIL_REGEXP }, allow_blank: true
  validates :commission_bps, numericality: { only_integer: true, in: 0..10_000 }

  before_validation :normalize_fields

  def commission_for(cents)
    (cents.to_i * commission_bps / 10_000.0).round
  end

  private

  def normalize_fields
    self.code = code.to_s.strip.upcase
    self.email = email.to_s.strip.downcase.presence
  end
end
