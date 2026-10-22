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
  validates :fee_notice_days, numericality: { only_integer: true, greater_than_or_equal_to: 1, less_than_or_equal_to: 365 }

  validates :payment_mode, presence: true, inclusion: { in: PAYMENT_MODES }
  validates :service_fee_percent, presence: true,
    numericality: { greater_than_or_equal_to: 0, less_than_or_equal_to: MAX_SERVICE_FEE_PERCENT }
  validates :service_fee_flat_cents, presence: true,
    numericality: { only_integer: true, greater_than_or_equal_to: 0, less_than_or_equal_to: MAX_SERVICE_FEE_FLAT_CENTS }
  validates :processing_fee_bearer, inclusion: { in: PROCESSING_FEE_BEARERS }
  validates :payout_schedule_text, presence: true, length: { maximum: MAX_PAYOUT_SCHEDULE_TEXT_LENGTH }
  validates :business_mailing_address, length: { maximum: 500 }, allow_blank: true
  normalizes :payout_schedule_text, with: ->(text) { text.squish }

  # ── Singleton accessor ──────────────────────────────────────────────
  # Uses singleton_guard column with unique index to prevent duplicate records.
  def self.instance
    settings = first_or_create!(
      singleton_guard: 0,
      payment_mode: "simulate",
      platform_name: "HåfaPass",
      service_fee_percent: DEFAULT_SERVICE_FEE_PERCENT,
      service_fee_flat_cents: DEFAULT_SERVICE_FEE_FLAT_CENTS,
      processing_fee_bearer: "platform",
      payout_schedule_text: DEFAULT_PAYOUT_SCHEDULE_TEXT
    )
    FeeChange.activate_due!(settings) if FeeChange.table_exists?
    settings.reload
  rescue ActiveRecord::RecordNotUnique
    # Another process beat us to it — just fetch the existing row
    settings = first!
    FeeChange.activate_due!(settings) if FeeChange.table_exists?
    settings.reload
  end

  LEGACY_SERVICE_FEE_PERCENT = 3.0
  LEGACY_SERVICE_FEE_FLAT_CENTS = 50

  # Post-deploy step (`bin/rails hafapass:adopt_launch_fee_terms`): move a row
  # still holding the untouched 3% + 50¢ defaults to the all-in launch fee.
  # Idempotent; an admin-chosen fee is never overwritten. Returns :adopted,
  # :already_adopted or :custom.
  def self.adopt_launch_fee_terms!(actor: nil)
    transaction do
      settings = instance
      settings.lock!
      fee = [settings.service_fee_percent.to_d, settings.service_fee_flat_cents]
      if fee == [DEFAULT_SERVICE_FEE_PERCENT.to_d, DEFAULT_SERVICE_FEE_FLAT_CENTS]
        :already_adopted
      elsif fee != [LEGACY_SERVICE_FEE_PERCENT.to_d, LEGACY_SERVICE_FEE_FLAT_CENTS]
        :custom
      else
        settings.update!(service_fee_percent: DEFAULT_SERVICE_FEE_PERCENT, service_fee_flat_cents: DEFAULT_SERVICE_FEE_FLAT_CENTS)
        AuditLogger.record!(action: "site_settings.fee_terms_updated", auditable: settings, actor: actor,
          before_data: { "service_fee_percent" => fee.first.to_s, "service_fee_flat_cents" => fee.last.to_s },
          after_data: { "service_fee_percent" => settings.service_fee_percent.to_s,
            "service_fee_flat_cents" => settings.service_fee_flat_cents.to_s },
          metadata: { "source" => "hafapass:adopt_launch_fee_terms" })
        :adopted
      end
    end
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
  # Keys for the current mode (see StripeCredentials). Work on an existing
  # payment uses the environment recorded on that payment instead.
  def stripe_secret_key
    StripeCredentials.secret_key(payment_mode)
  end

  # Returns the correct publishable key for the current mode.
  def stripe_publishable_key
    case payment_mode
    when "test"  then StripeCredentials.publishable_key("test")
    when "live"  then StripeCredentials.publishable_key("live") if can_enable_live?
    end
  end

  # ── Safety checks ───────────────────────────────────────────────────
  # Every test credential is present (secret, publishable, account, webhook).
  def can_enable_test?
    PaymentModeReadiness.ready?("test")
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
