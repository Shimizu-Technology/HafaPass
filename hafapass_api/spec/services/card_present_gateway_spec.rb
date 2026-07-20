require "rails_helper"

RSpec.describe CardPresentGateway do
  let(:account) { create(:card_present_account, :verified) }

  it "returns an exact, minimal result in simulation mode" do
    result = described_class.new(simulate: true).charge(
      account: account,
      amount_cents: 2500,
      currency: "usd",
      external_payment_id: "hp-123",
      idempotency_key: "sale-123"
    )

    expect(result).to have_attributes(amount_cents: 2500, currency: "usd", state: "CLOSED", result: "SUCCESS")
    expect(result.provider_payment_id).to start_with("sim_clover_")
    expect(result.provider_response.keys).to contain_exactly(
      "amount", "cardType", "externalPaymentId", "id", "last4", "result", "state"
    )
  end

  it "does not send a transaction when the account has not been verified" do
    account = create(:card_present_account)

    expect do
      described_class.new(simulate: true).charge(account: account, amount_cents: 2500, currency: "usd",
        external_payment_id: "hp-123", idempotency_key: "sale-123")
    end.to raise_error(described_class::PaymentError, /not payment ready/)
  end

  it "treats a non-exact provider response as unknown instead of issuing tickets" do
    response = Net::HTTPOK.new("1.1", "200", "OK")
    allow(response).to receive(:body).and_return({
      payment: {
        id: "clover-payment-1",
        amount: 2499,
        result: "SUCCESS",
        externalPaymentId: "hp-123",
        cardTransaction: { state: "CLOSED", cardType: "VISA", last4: "4242", token: "must-not-store" }
      },
      access_token: "must-not-store"
    }.to_json)
    connection = instance_double(Net::HTTP)
    allow(connection).to receive(:request).and_return(response)
    http_client = class_double(Net::HTTP)
    allow(http_client).to receive(:start).and_yield(connection)
    allow(ENV).to receive(:fetch).with("CLOVER_REST_PAY_BASE_URL").and_return("https://api.clover.com/connect")
    allow(ENV).to receive(:fetch).with("CLOVER_REST_PAY_ACCESS_TOKEN_ORGANIZATION_#{account.organization_id}").and_return("secret")

    expect do
      described_class.new(http_client: http_client, simulate: false).charge(
        account: account, amount_cents: 2500, currency: "usd", external_payment_id: "hp-123", idempotency_key: "sale-123"
      )
    end.to raise_error(described_class::ResultUnknown, /did not exactly match/)
  end

  it "treats Clover's explicit cancellation response as a known failure" do
    response = Net::HTTPResponse.new("1.1", "209", "Cancelled")
    allow(response).to receive(:body).and_return({ message: "cancelled" }.to_json)
    connection = instance_double(Net::HTTP, request: response)
    http_client = class_double(Net::HTTP)
    allow(http_client).to receive(:start).and_yield(connection)
    allow(ENV).to receive(:fetch).with("CLOVER_REST_PAY_BASE_URL").and_return("https://api.clover.com/connect")
    allow(ENV).to receive(:fetch).with("CLOVER_REST_PAY_ACCESS_TOKEN_ORGANIZATION_#{account.organization_id}").and_return("secret")

    expect do
      described_class.new(http_client: http_client, simulate: false).charge(
        account: account, amount_cents: 2500, currency: "usd", external_payment_id: "hp-123", idempotency_key: "sale-123"
      )
    end.to raise_error(described_class::PaymentError, /cancelled/)
  end

  it "treats a gateway 502 as an unknown result because the terminal may have charged" do
    response = Net::HTTPBadGateway.new("1.1", "502", "Bad Gateway")
    allow(response).to receive(:body).and_return({ message: "terminal unavailable" }.to_json)
    connection = instance_double(Net::HTTP, request: response)
    http_client = class_double(Net::HTTP)
    allow(http_client).to receive(:start).and_yield(connection)
    allow(ENV).to receive(:fetch).with("CLOVER_REST_PAY_BASE_URL").and_return("https://api.clover.com/connect")
    allow(ENV).to receive(:fetch).with("CLOVER_REST_PAY_ACCESS_TOKEN_ORGANIZATION_#{account.organization_id}").and_return("secret")

    expect do
      described_class.new(http_client: http_client, simulate: false).charge(
        account: account, amount_cents: 2500, currency: "usd", external_payment_id: "hp-123", idempotency_key: "sale-123"
      )
    end.to raise_error(described_class::ResultUnknown, /could not be confirmed/)
  end
end
