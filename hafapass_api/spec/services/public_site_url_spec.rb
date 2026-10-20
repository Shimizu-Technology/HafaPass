# frozen_string_literal: true

require "rails_helper"

RSpec.describe PublicSiteUrl do
  around do |example|
    original = %w[FRONTEND_URL PUBLIC_WEB_URL].index_with { |key| ENV[key] }
    %w[FRONTEND_URL PUBLIC_WEB_URL].each { |key| ENV.delete(key) }
    example.run
  ensure
    original.each { |key, value| value.nil? ? ENV.delete(key) : ENV[key] = value }
  end

  def in_environment(name)
    allow(Rails).to receive(:env).and_return(ActiveSupport::EnvironmentInquirer.new(name))
  end

  it "returns the configured URLs without a trailing slash" do
    ENV["FRONTEND_URL"] = "https://tickets.example.test///"
    ENV["PUBLIC_WEB_URL"] = " https://www.tickets.example.test/ "

    expect(described_class.frontend).to eq("https://tickets.example.test")
    expect(described_class.base).to eq("https://www.tickets.example.test")
    expect(described_class.event(build(:event, slug: "fiesta"))).to eq("https://www.tickets.example.test/events/fiesta")
  end

  it "falls back to the local Vite server only in development and test" do
    expect(described_class.frontend).to eq("http://localhost:5173")
    expect(described_class.base).to eq("http://localhost:5173")

    ENV["FRONTEND_URL"] = "http://localhost:5191"
    expect(described_class.base).to eq("http://localhost:5191")
  end

  %w[staging production].each do |name|
    context "in #{name}" do
      before { in_environment(name) }

      it "never falls back to localhost or a hardcoded domain" do
        expect { described_class.frontend }.to raise_error(described_class::ConfigurationError, /FRONTEND_URL/)
        ENV["FRONTEND_URL"] = "https://tickets.example.test"
        expect { described_class.base }.to raise_error(described_class::ConfigurationError, /PUBLIC_WEB_URL/)
      end

      it "fails the boot check until both public URLs are HTTPS" do
        expect { described_class.validate! }.to raise_error(described_class::ConfigurationError, /FRONTEND_URL, PUBLIC_WEB_URL/)

        ENV["FRONTEND_URL"] = "http://tickets.example.test"
        ENV["PUBLIC_WEB_URL"] = "https://tickets.example.test"
        expect { described_class.validate! }.to raise_error(described_class::ConfigurationError, /FRONTEND_URL must/)

        ENV["FRONTEND_URL"] = "https://tickets.example.test"
        expect { described_class.validate! }.not_to raise_error
      end
    end
  end

  it "skips the boot check in development and test" do
    expect { described_class.validate! }.not_to raise_error
  end
end
