require "rails_helper"

RSpec.describe StripeService do
  it "maps internal refund notes to Stripe's supported reason enum" do
    settings = instance_double(
      SiteSetting,
      simulate_mode?: false,
      stripe_secret_key: "sk_test_fake",
      payment_mode: "test"
    )
    allow(SiteSetting).to receive(:instance).and_return(settings)
    allow(Stripe::Refund).to receive(:create).and_return(OpenStruct.new(id: "re_test"))

    described_class.refund_payment(
      "pi_test",
      amount_cents: 500,
      reason: "event cancelled because of weather",
      idempotency_key: "refund-reason-test"
    )

    expect(Stripe::Refund).to have_received(:create).with(
      { payment_intent: "pi_test", amount: 500, reason: "requested_by_customer" },
      { api_key: "sk_test_fake", idempotency_key: "refund-reason-test" }
    )
  end
end
