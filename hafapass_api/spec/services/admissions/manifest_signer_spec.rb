# frozen_string_literal: true

require "rails_helper"

RSpec.describe Admissions::ManifestSigner do
  it "does not memoize a configured public-only key after validation fails" do
    original_defined = described_class.instance_variable_defined?(:@private_key)
    original_key = described_class.instance_variable_get(:@private_key) if original_defined
    described_class.remove_instance_variable(:@private_key) if original_defined
    public_only_pem = OpenSSL::PKey::RSA.generate(2048).public_key.to_pem
    allow(ENV).to receive(:[]).and_call_original
    allow(ENV).to receive(:[]).with("ADMISSION_MANIFEST_PRIVATE_KEY_PEM").and_return(public_only_pem)

    2.times do
      expect { described_class.sign("manifest-digest") }
        .to raise_error(described_class::ConfigurationError, /must contain an RSA private key/)
      expect(described_class.instance_variable_defined?(:@private_key)).to be(false)
    end
  ensure
    described_class.remove_instance_variable(:@private_key) if described_class.instance_variable_defined?(:@private_key)
    described_class.instance_variable_set(:@private_key, original_key) if original_defined
  end
end
