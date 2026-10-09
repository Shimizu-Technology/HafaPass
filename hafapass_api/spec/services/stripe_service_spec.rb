require "rails_helper"

RSpec.describe StripeService do
  it "refuses legacy live mode when current provider evidence is not approved" do
    settings = instance_double(
      SiteSetting,
      simulate_mode?: false,
      live_mode?: true,
      can_enable_live?: false,
      stripe_secret_key: "sk_live_present_but_unapproved",
      payment_mode: "live"
    )
    allow(SiteSetting).to receive(:instance).and_return(settings)

    expect do
      described_class.refund_payment("pi_live", idempotency_key: "refund-live-unapproved")
    end.to raise_error(described_class::PaymentError, /disabled until current provider evidence/)
  end

  it "maps internal refund notes to Stripe's supported reason enum" do
    settings = instance_double(
      SiteSetting,
      simulate_mode?: false,
      live_mode?: false,
      stripe_secret_key: "sk_test_fake",
      payment_mode: "test"
    )
    allow(SiteSetting).to receive(:instance).and_return(settings)
    refunds = double("refunds service")
    client = instance_double(Stripe::StripeClient, v1: double("v1", refunds: refunds))
    allow(Stripe::StripeClient).to receive(:new).with("sk_test_fake").and_return(client)
    allow(refunds).to receive(:create).and_return(OpenStruct.new(id: "re_test"))

    described_class.refund_payment(
      "pi_test",
      amount_cents: 500,
      reason: "event cancelled because of weather",
      idempotency_key: "refund-reason-test"
    )

    expect(refunds).to have_received(:create).with(
      { payment_intent: "pi_test", amount: 500, reason: "requested_by_customer", metadata: { hafapass_refund_key: "refund-reason-test" } },
      { idempotency_key: "refund-reason-test" }
    )
  end

  describe ".find_refund" do
    let(:refunds_api) { double("refunds API") }
    let(:list) { double("paginated refund list") }

    before do
      settings = instance_double(SiteSetting, simulate_mode?: false, live_mode?: false,
        stripe_secret_key: "sk_test_lookup", payment_mode: "test")
      allow(SiteSetting).to receive(:instance).and_return(settings)
      client = instance_double(Stripe::StripeClient, v1: double("v1 services", refunds: refunds_api))
      allow(Stripe::StripeClient).to receive(:new).with("sk_test_lookup").and_return(client)
      allow(refunds_api).to receive(:list).with({ payment_intent: "pi_lookup", limit: 100 }, {}).and_return(list)
    end

    it "looks through every page and matches the durable operation metadata rather than the amount" do
      unrelated = OpenStruct.new(id: "re_other", amount: 1000, metadata: { "hafapass_refund_key" => "other-key" })
      matching = OpenStruct.new(id: "re_found", amount: 1000, metadata: { "hafapass_refund_key" => "our-key" })
      allow(list).to receive(:auto_paging_each).and_yield(unrelated).and_yield(matching)

      expect(described_class.find_refund("pi_lookup", idempotency_key: "our-key")).to eq(matching)
      expect(list).to have_received(:auto_paging_each)
    end

    it "returns no match only after scanning all provider refunds" do
      allow(list).to receive(:auto_paging_each).and_yield(OpenStruct.new(metadata: {}))
      expect(described_class.find_refund("pi_lookup", idempotency_key: "missing-key")).to be_nil
    end

    it "continues past null metadata to recover a matching refund on a later page" do
      unrelated = OpenStruct.new(id: "re_no_metadata", metadata: nil)
      matching = OpenStruct.new(id: "re_after_null", metadata: { "hafapass_refund_key" => "our-key" })
      allow(list).to receive(:auto_paging_each).and_yield(unrelated).and_yield(matching)

      expect(described_class.find_refund("pi_lookup", idempotency_key: "our-key")).to eq(matching)
    end

    it "quarantines duplicate metadata matches instead of guessing one operation" do
      first = OpenStruct.new(id: "re_one", metadata: { "hafapass_refund_key" => "duplicate-key" })
      second = OpenStruct.new(id: "re_two", metadata: { "hafapass_refund_key" => "duplicate-key" })
      allow(list).to receive(:auto_paging_each).and_yield(first).and_yield(second)
      expect { described_class.find_refund("pi_lookup", idempotency_key: "duplicate-key") }
        .to raise_error(described_class::PaymentError, /Multiple provider refunds/)
    end
  end
  it "routes an old test payment by its snapshot after the global mode changes" do
    payment = create(:payment, provider_environment: "test", provider_account_id: "acct_original")
    SiteSetting.instance.update!(payment_mode: "simulate")
    allow(ENV).to receive(:[]).and_call_original
    allow(ENV).to receive(:[]).with("STRIPE_TEST_SECRET_KEY").and_return("sk_test_original")
    refunds = double("refunds API")
    client = instance_double(Stripe::StripeClient, v1: double("v1", refunds: refunds))
    allow(Stripe::StripeClient).to receive(:new).with("sk_test_original").and_return(client)
    expect(refunds).to receive(:create).with(anything, hash_including(stripe_account: "acct_original"))
    described_class.refund_payment(payment.provider_payment_id, payment: payment, idempotency_key: "snapshot")
  end

  it "does not claim a real intent was cancelled when global mode is simulate" do
    expect { described_class.cancel_payment_intent("pi_real", idempotency_key: "cancel-real") }
      .to raise_error(described_class::PaymentError, /real payment cannot be cancelled/)
  end

  it "requires finance review for legacy external payments without an environment snapshot" do
    payment = create(:payment, provider_environment: nil)
    expect { described_class.refund_payment(payment.provider_payment_id, payment: payment, idempotency_key: "legacy") }
      .to raise_error(described_class::PaymentError, /context is missing/)
  end
end
