# frozen_string_literal: true

class ConnectedAccount < ApplicationRecord
  PROVIDERS = %w[paypal manual stripe legacy_manual].freeze

  belongs_to :organization
  has_many :payouts, dependent: :restrict_with_error

  enum :status, {
    pending: 0, onboarding: 1, requirements_due: 2, ready: 3, restricted: 4, disabled: 5
  }, prefix: true

  validates :provider, inclusion: { in: PROVIDERS }, uniqueness: { scope: :organization_id }
  validates :provider_account_id, uniqueness: { scope: :provider }, allow_blank: true
  validates :country, :currency, presence: true
  validates :currency, length: { is: 3 }

  def payout_ready?
    status_ready? && charges_enabled? && payouts_enabled? && details_submitted? && requirements_due.blank?
  end
end
