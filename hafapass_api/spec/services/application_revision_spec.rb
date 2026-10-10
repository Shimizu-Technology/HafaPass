# frozen_string_literal: true

require "rails_helper"

RSpec.describe ApplicationRevision do
  around do |example|
    original = ENV.to_h.slice("RENDER_GIT_COMMIT", "GIT_SHA", "COMMIT_REF")
    ENV.delete("RENDER_GIT_COMMIT")
    ENV.delete("GIT_SHA")
    ENV.delete("COMMIT_REF")
    example.run
  ensure
    %w[RENDER_GIT_COMMIT GIT_SHA COMMIT_REF].each { |name| original.key?(name) ? ENV[name] = original[name] : ENV.delete(name) }
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

  it "binds approvals and progress to the actual Render commit ahead of stale manual values" do
    ENV["GIT_SHA"] = "a" * 40
    ENV["COMMIT_REF"] = "b" * 40
    ENV["RENDER_GIT_COMMIT"] = "c" * 40
    expect(described_class.current).to eq("c" * 40)
    expect(PilotReadiness.application_revision).to eq("c" * 40)
    expect(described_class).to be_configured
    ENV["RENDER_GIT_COMMIT"] = "d" * 64
    expect(described_class.current).to eq("d" * 64)
    expect(described_class).to be_configured
  end

  ["main", "a" * 7, " " * 40].each do |invalid|
    it "does not fall back to a valid manual identity for invalid Render revision #{invalid.inspect}" do
      ENV["GIT_SHA"] = "a" * 40
      ENV["COMMIT_REF"] = "b" * 40
      ENV["RENDER_GIT_COMMIT"] = invalid
      expect(described_class.current).to eq(invalid)
      expect(described_class).not_to be_configured
    end
  end

  it "retains non-Render fallbacks when the platform variable is absent or empty" do
    ENV["RENDER_GIT_COMMIT"] = ""
    ENV["GIT_SHA"] = "a" * 40
    expect(described_class.current).to eq("a" * 40)
    ENV["GIT_SHA"] = ""
    ENV["COMMIT_REF"] = "b" * 40
    expect(described_class.current).to eq("b" * 40)
  end

  it "does not grant production approvals a shared development identity" do
    allow(Rails.env).to receive(:production?).and_return(true)
    expect(described_class.current).to be_nil
    expect(described_class).not_to be_configured
    expect(PilotReadiness.active_approval(create(:event))).to be_nil
  end

  it "requires a complete commit digest for production configuration" do
    ENV["COMMIT_REF"] = "main"
    expect(described_class).not_to be_configured
  end
end
