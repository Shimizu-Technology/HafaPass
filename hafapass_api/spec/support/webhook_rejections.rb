# The rejected-webhook counter buffers in memory per process; start every example clean.
RSpec.configure do |config|
  config.before { Operations::WebhookRejections.reset! }
end
