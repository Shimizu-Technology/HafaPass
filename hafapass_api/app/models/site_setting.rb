# frozen_string_literal: true

class SiteSetting < ApplicationRecord
  # Singleton pattern — only one record should ever exist
  PAYMENT_MODES = %w[simulate test live].freeze

  validates :payment_mode, presence: true, inclusion: { in: PAYMENT_MODES }

  # ── Singleton accessor ──────────────────────────────────────────────
  def self.instance
    first_or_create!(
      payment_mode: 'simulate',
      platform_name: 'HafaPass',
      platform_email: 'tickets@hafapass.com',
      service_fee_percent: 3.0,
      service_fee_flat_cents: 50
    )
  end

  # ── Mode helpers ────────────────────────────────────────────────────
  def simulate_mode?
    payment_mode == 'simulate'
  end

  def test_mode?
    payment_mode == 'test'
  end

  def live_mode?
    payment_mode == 'live'
  end

  # True when Stripe API calls will actually be made (test or live)
  def stripe_enabled?
    test_mode? || live_mode?
  end

  # ── Stripe key resolution ───────────────────────────────────────────
  # Returns the correct secret key for the current mode.
  # Falls back: STRIPE_TEST_SECRET_KEY → STRIPE_SECRET_KEY (for test mode)
  def stripe_secret_key
    case payment_mode
    when 'test'  then ENV['STRIPE_TEST_SECRET_KEY'].presence || ENV['STRIPE_SECRET_KEY']
    when 'live'  then ENV['STRIPE_LIVE_SECRET_KEY']
    end
  end

  # Returns the correct publishable key for the current mode.
  def stripe_publishable_key
    case payment_mode
    when 'test'  then ENV['STRIPE_TEST_PUBLISHABLE_KEY'].presence || ENV['STRIPE_PUBLISHABLE_KEY']
    when 'live'  then ENV['STRIPE_LIVE_PUBLISHABLE_KEY']
    end
  end

  # ── Safety checks ───────────────────────────────────────────────────
  def can_enable_test?
    (ENV['STRIPE_TEST_SECRET_KEY'].presence || ENV['STRIPE_SECRET_KEY']).present?
  end

  def can_enable_live?
    ENV['STRIPE_LIVE_SECRET_KEY'].present?
  end

  # ── Guards ──────────────────────────────────────────────────────────
  before_destroy :prevent_destroy

  private

  def prevent_destroy
    raise ActiveRecord::RecordNotDestroyed, "Cannot delete site settings"
  end
end
