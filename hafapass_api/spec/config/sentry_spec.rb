require "rails_helper"

RSpec.describe "Sentry configuration" do
  let(:request_type) { Struct.new(:data) }
  let(:event_type) { Struct.new(:request) }

  it "recursively filters sensitive request data before reporting" do
    event = event_type.new(request_type.new({
      "buyer" => { "email" => "guest@example.com", "phone" => "671-555-0100" },
      "payment" => { "card_number" => "4242424242424242", "cvc" => "123" },
      "event_id" => 42
    }))

    Sentry.configuration.before_send.call(event, nil)

    expect(event.request.data).to include("event_id" => 42)
    expect(event.request.data.dig("buyer", "email")).to eq("[FILTERED]")
    expect(event.request.data.dig("buyer", "phone")).to eq("[FILTERED]")
    expect(event.request.data.dig("payment", "card_number")).to eq("[FILTERED]")
    expect(event.request.data.dig("payment", "cvc")).to eq("[FILTERED]")
  end

  it "drops unstructured request bodies" do
    event = event_type.new(request_type.new("raw payment body"))

    Sentry.configuration.before_send.call(event, nil)

    expect(event.request.data).to be_nil
  end
end
