# frozen_string_literal: true

require "rails_helper"

# Uses a real Sentry client with an in-memory transport, so the SDK's own
# queueing and failure behavior is what's under test.
RSpec.describe MonitoringTestAlert do
  let(:transport) { Sentry.get_current_client.transport }

  around do |example|
    Sentry.init do |config|
      config.dsn = "https://public@example.invalid/1"
      config.environment = "test"
      config.enabled_environments = %w[test]
      config.transport.transport_class = Sentry::DummyTransport
      config.sdk_logger = Logger.new(nil)
    end
    example.run
  ensure
    Sentry.close
    load Rails.root.join("config/initializers/sentry.rb")
  end

  it "delivers synchronously: the event is at the transport when send! returns" do
    event_id = described_class.send!(kind: "checkout")

    expect(event_id).to be_present
    expect(transport.events.map(&:event_id)).to eq([event_id])
    expect(transport.events.first.message).to start_with("[TEST]")
  end

  it "does not report success when the SDK's background queue is full and silently drops queued events" do
    # What a queued send does under overflow: perform returns false and the SDK
    # still hands back an event object (sentry-ruby 5.28.1 client.rb capture_event).
    allow(Sentry.background_worker).to receive(:perform).and_return(false)
    queued = Sentry.capture_message("queued drop")
    expect(queued).to be_present                       # the SDK says "event" ...
    expect(transport.events).to be_empty               # ... but nothing was delivered

    event_id = described_class.send!(kind: "checkout")  # the drill bypasses that queue entirely
    expect(event_id).to be_present
    expect(transport.events.map(&:event_id)).to eq([event_id])
  end

  it "returns nil when the network send fails" do
    allow(transport).to receive(:send_event).and_raise(Sentry::ExternalError, "boom")
    expect(described_class.send!(kind: "checkout")).to be_nil
  end

  it "returns nil when the project is rate limited" do
    allow(transport).to receive(:is_rate_limited?).with("error").and_return(true)
    expect(described_class.send!(kind: "checkout")).to be_nil
    expect(transport.events).to be_empty
  end

  it "returns nil when the environment isn't enabled" do
    Sentry.configuration.enabled_environments = %w[production]
    expect(described_class.send!(kind: "checkout")).to be_nil
  end

  it "rejects unknown kinds" do
    expect { described_class.send!(kind: "nope") }.to raise_error(ArgumentError)
  end
end
