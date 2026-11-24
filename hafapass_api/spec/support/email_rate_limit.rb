# Provider contract tests exercise transport retries without wall-clock pacing.
# Throughput behavior has dedicated examples using the real database limiter.
RSpec.configure do |config|
  config.before do |example|
    unless example.metadata[:email_rate_limit]
      allow(EmailRateSlot).to receive(:reserve!).and_return(0)
      allow(EmailRateSlot).to receive(:dispatch!).and_yield
    end
  end
end
