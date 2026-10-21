# frozen_string_literal: true

require "rails_helper"
require_relative "../../config/encryption_configuration"

RSpec.describe EncryptionConfiguration do
  it "allows fallback keys only in development and test, and lets staging boot unconfigured" do
    expect(described_class.keys(environment: "test", env: {})).to eq(described_class.keys(environment: "development", env: {}))
    expect(described_class.keys(environment: "staging", env: {})).to be_nil
    expect { described_class.keys(environment: "production", env: {}) }.to raise_error(/ACTIVE_RECORD_ENCRYPTION_PRIMARY_KEY is required/)
  end

  it "requires every deployed key and uses the supplied environment values" do
    env = %w[PRIMARY_KEY DETERMINISTIC_KEY KEY_DERIVATION_SALT].index_with { |key| "fixture-#{key}" }
      .transform_keys { |key| "ACTIVE_RECORD_ENCRYPTION_#{key}" }
    expect(described_class.keys(environment: "production", env: env).values).to eq(env.values)
    expect(described_class.keys(environment: "staging", env: env).values).to eq(env.values)
    env.each_key do |key|
      expect { described_class.keys(environment: "production", env: env.merge(key => "")) }.to raise_error("#{key} is required")
      expect(described_class.keys(environment: "staging", env: env.merge(key => ""))).to be_nil
    end
  end
end
