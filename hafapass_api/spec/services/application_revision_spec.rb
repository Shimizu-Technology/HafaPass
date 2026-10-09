# frozen_string_literal: true

require "rails_helper"

RSpec.describe ApplicationRevision do
  around do |example|
    original = ENV.to_h.slice("GIT_SHA", "COMMIT_REF")
    ENV.delete("GIT_SHA")
    ENV.delete("COMMIT_REF")
    example.run
  ensure
    %w[GIT_SHA COMMIT_REF].each { |name| original.key?(name) ? ENV[name] = original[name] : ENV.delete(name) }
  end

  it "binds readiness to changes in COMMIT_REF" do
    ENV["COMMIT_REF"] = "a" * 40
    expect(PilotReadiness.application_revision).to eq("a" * 40)
    ENV["COMMIT_REF"] = "b" * 40
    expect(PilotReadiness.application_revision).to eq("b" * 40)
    expect(described_class).to be_configured
  end

  it "uses GIT_SHA consistently when both deployment variables are present" do
    ENV["GIT_SHA"] = "a" * 40
    ENV["COMMIT_REF"] = "b" * 40
    expect(described_class.current).to eq("a" * 40)
    expect(PilotReadiness.application_revision).to eq(described_class.current)
  end

  it "does not grant production approvals a shared development identity" do
    allow(Rails.env).to receive(:production?).and_return(true)
    expect(described_class.current).to be_nil
    expect(described_class).not_to be_configured
  end

  it "requires a complete commit digest for production configuration" do
    ENV["COMMIT_REF"] = "main"
    expect(described_class).not_to be_configured
  end
end
