# Keep throttle counters real within an example and isolated between examples.
# Database rollback does not reset Redis, and NullStore hides rate limits.
# Each owned memory store is discarded; configured/shared Redis is never cleared.
RSpec.configure do |config|
  config.around do |example|
    configured_store = Rack::Attack.cache.store
    Rack::Attack.cache.store = ActiveSupport::Cache::MemoryStore.new
    example.run
  ensure
    Rack::Attack.cache.store = configured_store
  end
end
