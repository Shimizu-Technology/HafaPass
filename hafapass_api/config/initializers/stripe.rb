# Stripe configuration
# Only initialize Stripe if the secret key is present.
# The app runs without Stripe keys for development/testing (mock checkout).
if ENV["STRIPE_SECRET_KEY"].present?
  Stripe.api_key = ENV["STRIPE_SECRET_KEY"]
end
