# frozen_string_literal: true

require "webmock"
require "webmock/rspec/matchers"

# Provider specs opt in with `:webmock`; every other example keeps real
# adapters so unrelated specs are unaffected.
WebMock.disable!

RSpec.configure do |config|
  config.include WebMock::API, :webmock
  config.include WebMock::Matchers, :webmock
  config.around(:each, :webmock) do |example|
    WebMock.enable!
    WebMock.disable_net_connect!
    example.run
  ensure
    WebMock.reset!
    WebMock.allow_net_connect!
    WebMock.disable!
  end
end
