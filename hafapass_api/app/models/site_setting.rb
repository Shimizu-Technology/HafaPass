# frozen_string_literal: true

class SiteSetting < ApplicationRecord
  # Singleton pattern — only one record should ever exist
  PAYMENT_MODES = %w[simulate test live].freeze
  # Who pays the actual card-processing cost of a paid order. "platform" means
  # the buyer fee is all-in: HåfaPass pays Stripe out of it and the organizer
  # keeps the ticket price. "organizer" is the legacy rule, where actual
  # processing is deducted from organizer proceeds. Orders snapshot this value.
  PROCESSING_FEE_BEARERS = %w[platform organizer].freeze
  DEFAULT_SERVICE_FEE_PERCENT = 5.0
  DEFAULT_SERVICE_FEE_FLAT_CENTS = 100
  DEFAULT_PAYOUT_SCHEDULE_TEXT = "within 3 business days after your event"
  MAX_SERVICE_FEE_PERCENT = 25
  MAX_SERVICE_FEE_FLAT_CENTS = 1_000
  MAX_PAYOUT_SCHEDULE_TEXT_LENGTH = 200

  validates :payment_mode, presence: true, inclusion: { in: PAYMENT_MODES }
  validates :service_fee_percent, presence: true,
    numericality: { greater_than_or_equal_to: 0, less_than_or_equal_to: MAX_SERVICE_FEE_PERCENT }
  validates :service_fee_flat_cents, presence: true,
    numericality: { only_integer: true, greater_than_or_equal_to: 0, less_than_or_equal_to: MAX_SERVICE_FEE_FLAT_CENTS }
  validates :processing_fee_bearer, inclusion: { in: PROCESSING_FEE_BEARERS }
  validates :payout_schedule_text, presence: true, length: { maximum: MAX_PAYOUT_SCHEDULE_TEXT_LENGTH }
  normalizes :payout_schedule_text, with: ->(text) { text.squish }

  # ── Singleton accessor ──────────────────────────────────────────────
  # Uses singleton_guard column with unique index to prevent duplicate records.
  def self.instance
    first_or_create!(
      singleton_guard: 0,
      payment_mode: "simulate",
      platform_name: "HåfaPass",
      platform_email: "tickets@hafapass.com",
      service_fee_percent: DEFAULT_SERVICE_FEE_PERCENT,
      service_fee_flat_cents: DEFAULT_SERVICE_FEE_FLAT_CENTS,
      processing_fee_bearer: "platform",
      payout_schedule_text: DEFAULT_PAYOUT_SCHEDULE_TEXT
    )
  rescue ActiveRecord::RecordNotUnique
    # Another process beat us to it — just fetch the existing row
    first!
  end

  # ── Mode helpers ────────────────────────────────────────────────────
  def simulate_mode?
    payment_mode == "simulate"
  end

  def test_mode?
    payment_mode == "test"
  end

  def live_mode?
    payment_mode == "live"
  end

  def platform_bears_processing?
    processing_fee_bearer == "platform"
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
    when "test"  then ENV["STRIPE_TEST_SECRET_KEY"].presence || ENV["STRIPE_SECRET_KEY"]
    when "live"  then ENV["STRIPE_LIVE_SECRET_KEY"]
    end
  end

  # Returns the correct publishable key for the current mode.
  def stripe_publishable_key
    case payment_mode
    when "test"  then ENV["STRIPE_TEST_PUBLISHABLE_KEY"].presence || ENV["STRIPE_PUBLISHABLE_KEY"]
    when "live"  then ENV["STRIPE_LIVE_PUBLISHABLE_KEY"] if can_enable_live?
    end
  end

  # ── Safety checks ───────────────────────────────────────────────────
  def can_enable_test?
    (ENV["STRIPE_TEST_SECRET_KEY"].presence || ENV["STRIPE_SECRET_KEY"]).present?
  end

  def can_enable_live?
    PlatformCapabilities.enabled?("stripe_live")
  end

  def stripe_live_configured?
    PlatformCapabilities.configured?("stripe_live")
  end

  # ── Guards ──────────────────────────────────────────────────────────
  before_destroy :prevent_destroy

  private

  def prevent_destroy
    raise ActiveRecord::RecordNotDestroyed, "Cannot delete site settings"
  end
end
