require "rails_helper"
require "socket"
require "uri"

RSpec.describe StripeService do
  before do
    allow(ENV).to receive(:[]).and_call_original
    allow(ENV).to receive(:[]).with("STRIPE_TEST_PLATFORM_ACCOUNT_ID").and_return("acct_testplatform")
  end
  def accounts_api(id = "acct_testplatform")
    double("accounts API", retrieve_current: OpenStruct.new(id: id))
  end
  it "limits a new ticket intent to cards without incompatible dynamic method parameters" do
    SiteSetting.instance.update!(payment_mode: "test")
    allow(ENV).to receive(:[]).with("STRIPE_TEST_SECRET_KEY").and_return("rk_test_cards")
    order = create(:order)
    intents = double("payment intents API")
    client = instance_double(Stripe::StripeClient, v1: double("v1", accounts: accounts_api, payment_intents: intents))
    allow(Stripe::StripeClient).to receive(:new).with("rk_test_cards").and_return(client)
    expect(intents).to receive(:create) do |params, options|
      expect(params).to include(allowed_payment_method_types: ["card"], amount: order.total_cents, currency: "usd")
      %i[automatic_payment_methods payment_method_types excluded_payment_method_types payment_method_configuration].each do |field|
        expect(params).not_to have_key(field)
      end
      expect(options).to include(idempotency_key: "card-policy")
      OpenStruct.new(id: "pi_test_cards")
    end
    described_class.create_payment_intent(order, idempotency_key: "card-policy")
  end
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
    client = instance_double(Stripe::StripeClient, v1: double("v1", refunds: refunds, accounts: accounts_api))
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
      client = instance_double(Stripe::StripeClient, v1: double("v1 services", refunds: refunds_api, accounts: accounts_api))
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
    client = instance_double(Stripe::StripeClient, v1: double("v1", refunds: refunds, accounts: accounts_api))
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
  it "rejects a different platform account even when the key still belongs to test mode" do
    payment = create(:payment)
    allow(ENV).to receive(:[]).with("STRIPE_TEST_SECRET_KEY").and_return("sk_test_changed")
    client = instance_double(Stripe::StripeClient, v1: double("v1", accounts: accounts_api("acct_otherplatform")))
    allow(Stripe::StripeClient).to receive(:new).with("sk_test_changed").and_return(client)
    expect { described_class.cancel_payment_intent(payment.provider_payment_id, payment: payment, idempotency_key: "wrong-account") }
      .to raise_error(described_class::PaymentError, /different platform account/)
  end

  it "rejects live credentials in the test slot before constructing any client" do
    payment = create(:payment)
    allow(ENV).to receive(:[]).with("STRIPE_TEST_SECRET_KEY").and_return("rk_live_misconfigured")
    expect(Stripe::StripeClient).not_to receive(:new)
    expect { described_class.refund_payment(payment.provider_payment_id, payment: payment, idempotency_key: "wrong-mode") }
      .to raise_error(described_class::PaymentError, /do not match the payment environment/)
  end

  it "requires finance review for a legacy payment with unknown platform ownership" do
    payment = create(:payment, provider_platform_account_id: nil)
    allow(ENV).to receive(:[]).with("STRIPE_TEST_SECRET_KEY").and_return("sk_test_present")
    expect { described_class.find_refund(payment.provider_payment_id, payment: payment, idempotency_key: "unknown-platform") }
      .to raise_error(described_class::PaymentError, /platform account context is missing/)
  end
  it "retrieves expanded fee evidence using the original verified platform and connected scope" do
    payment = create(:payment, provider_account_id: "acct_organizer")
    allow(ENV).to receive(:[]).with("STRIPE_TEST_SECRET_KEY").and_return("rk_test_feeproof")
    intents = double("payment intents API")
    client = instance_double(Stripe::StripeClient, v1: double("v1", accounts: accounts_api, payment_intents: intents))
    allow(Stripe::StripeClient).to receive(:new).with("rk_test_feeproof").and_return(client)
    expect(intents).to receive(:retrieve).with(payment.provider_payment_id,
      { expand: ["latest_charge.balance_transaction"] }, { stripe_account: "acct_organizer" })
    described_class.retrieve_fee_payment_intent(payment)
  end
  it "sends the card policy through the real SDK20 HTTP encoder and API-version header" do
    SiteSetting.instance.update!(payment_mode: "test")
    allow(ENV).to receive(:[]).with("STRIPE_TEST_SECRET_KEY").and_return("rk_test_http_transport")
    listener = TCPServer.new("127.0.0.1", 0)
    port = listener.addr[1]
    requests = Queue.new
    worker = Thread.new do
      2.times do
        socket = listener.accept
        request_line = socket.gets
        headers = {}
        while (line = socket.gets) && line != "\r\n"
          name, value = line.split(":", 2)
          headers[name.downcase] = value.strip
        end
        body = socket.read(headers.fetch("content-length", "0").to_i)
        requests << { request_line: request_line, headers: headers, body: body }
        data = if URI.parse(request_line.split[1]).path == "/v1/account"
          { id: "acct_testplatform", object: "account" }
        else
          { id: "pi_http_transport", object: "payment_intent", client_secret: "pi_http_secret",
            allowed_payment_method_types: ["card"], payment_method_types: ["card"],
            automatic_payment_methods: nil, status: "requires_payment_method" }
        end
        response = JSON.generate(data)
        socket.write("HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: #{response.bytesize}\r\nConnection: close\r\n\r\n#{response}")
        socket.close
      end
    rescue IOError
      raise unless listener.closed?
    end
    allow(Stripe::StripeClient).to receive(:new).and_wrap_original do |original, key|
      original.call(key, api_base: "http://127.0.0.1:#{port}")
    end
    returned = described_class.create_payment_intent(create(:order), idempotency_key: "http-card-policy")
    worker.value
    first, creation = 2.times.map { requests.pop }
    expect(URI.parse(first[:request_line].split[1]).path).to eq("/v1/account")
    expect(creation[:request_line].split.first).to eq("POST")
    expect(URI.parse(creation[:request_line].split[1]).path).to eq("/v1/payment_intents")
    expect(creation[:headers]).to include("stripe-version" => "2026-09-30.endive", "idempotency-key" => "http-card-policy")
    form = URI.decode_www_form(creation[:body]).to_h
    expect(form["allowed_payment_method_types[0]"]).to eq("card")
    %w[automatic_payment_methods payment_method_types excluded_payment_method_types payment_method_configuration].each do |field|
      expect(form.keys).not_to include(a_string_starting_with(field))
    end
    expect(described_class.card_only_intent?(returned)).to be(true)
  ensure
    listener&.close
    worker&.join(1)
    worker&.kill if worker&.alive?
  end
end
