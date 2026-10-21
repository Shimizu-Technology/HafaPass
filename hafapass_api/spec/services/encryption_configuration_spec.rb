# frozen_string_literal: true

require "rails_helper"
require_relative "../../config/encryption_configuration"

RSpec.describe EncryptionConfiguration do
  it "allows fallback keys only in development and test" do
    expect(described_class.keys(environment: "test", env: {})).to eq(described_class.keys(environment: "development", env: {}))
    %w[production staging].each do |environment|
      expect { described_class.keys(environment: environment, env: {}) }.to raise_error(/ACTIVE_RECORD_ENCRYPTION_PRIMARY_KEY is required/)
    end
  end

  it "requires every deployed key and uses the supplied environment values" do
    env = %w[PRIMARY_KEY DETERMINISTIC_KEY KEY_DERIVATION_SALT].index_with { |key| "fixture-#{key}" }
      .transform_keys { |key| "ACTIVE_RECORD_ENCRYPTION_#{key}" }
    expect(described_class.keys(environment: "production", env: env).values).to eq(env.values)
    env.each_key do |key|
      expect { described_class.keys(environment: "production", env: env.merge(key => "")) }.to raise_error("#{key} is required")
    end
  end
end
