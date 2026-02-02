# frozen_string_literal: true

# Stripe API configuration
# ========================
# Keys are loaded dynamically based on SiteSetting.payment_mode:
#   simulate → No Stripe calls, everything faked
#   test     → Uses STRIPE_TEST_SECRET_KEY (Stripe sandbox, no real money)
#   live     → Uses STRIPE_LIVE_SECRET_KEY (real charges)
#
# The correct key is set per-request by StripeService.configure_stripe!
# so we don't set Stripe.api_key globally here.

# Log which keys are available at boot
test_key = ENV['STRIPE_TEST_SECRET_KEY'].presence || ENV['STRIPE_SECRET_KEY']
live_key = ENV['STRIPE_LIVE_SECRET_KEY']

if test_key.present?
  Rails.logger.info "\u2705 Stripe test keys available"
else
  Rails.logger.info "\u26a0\ufe0f  No Stripe test keys — test mode unavailable"
end

if live_key.present?
  Rails.logger.info "\u2705 Stripe live keys available"
else
  Rails.logger.info "\u2139\ufe0f  No Stripe live keys — live mode unavailable (expected in development)"
end
