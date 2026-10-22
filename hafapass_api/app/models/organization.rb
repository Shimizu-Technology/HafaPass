# frozen_string_literal: true

class Organization < ApplicationRecord
  has_many :venue_layouts, dependent: :restrict_with_error
  has_one :organizer_tax_information, dependent: :restrict_with_error
  has_one :organizer_profile, dependent: :restrict_with_error
  has_many :organization_memberships, dependent: :restrict_with_error
  has_many :members, through: :organization_memberships, source: :user
  has_many :events, dependent: :restrict_with_error
  has_many :event_staff_assignments, dependent: :restrict_with_error
  has_many :connected_accounts, dependent: :restrict_with_error
  has_many :settlements, dependent: :restrict_with_error
  has_many :payouts, dependent: :restrict_with_error
  has_many :live_money_proof_reviews, dependent: :restrict_with_error
  has_many :balance_adjustments, dependent: :restrict_with_error
  has_many :audit_logs, dependent: :restrict_with_error
  has_many :scanner_devices, dependent: :restrict_with_error
  has_many :admission_manifests, dependent: :restrict_with_error
  has_many :admission_actions, dependent: :restrict_with_error
  has_one :card_present_account, dependent: :restrict_with_error
  has_many :card_present_payment_attempts, dependent: :restrict_with_error
  has_many :organizer_follows, dependent: :destroy

  enum :status, { active: 0, suspended: 1, archived: 2 }, prefix: true

  validates :name, :slug, :timezone, :currency, presence: true
  validates :slug, uniqueness: true
  validates :currency, length: { is: 3 }
  validates :marketing_mailing_address, length: { maximum: 500 }, allow_blank: true
  validate :certified_marketing_address_is_postal

  before_validation :generate_slug, if: -> { slug.blank? || name_changed? }

  def payout_account
    connected_accounts.find(&:payout_ready?)
  end

  def payout_ready?
    status_active? && payout_account.present?
  end

  def marketing_postal_address_ready?
    marketing_address_certified_at.present? && marketing_postal_address_valid?
  end

  private

  def certified_marketing_address_is_postal
    return if marketing_address_certified_at.blank?

    unless marketing_postal_address_valid?
      errors.add(:marketing_mailing_address, "must include a street or PO Box, locality, and postal code")
    end
  end

  def marketing_postal_address_valid?
    address = marketing_mailing_address.to_s.strip
    address.length >= 12 && address.match?(/\d/) && address.match?(/\b\d{5}(?:-\d{4})?\b/) &&
      address.match?(/[[:alpha:]]/) && !address.match?(/https?:\/\/|@/i)
  end

  def generate_slug
    base = name.to_s.parameterize.presence || "organization"
    candidate = base
    suffix = 2
    while Organization.where.not(id: id).exists?(slug: candidate)
      candidate = "#{base}-#{suffix}"
      suffix += 1
    end
    self.slug = candidate
  end
end
