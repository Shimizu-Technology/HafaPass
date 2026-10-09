# frozen_string_literal: true

require "rails_helper"

RSpec.describe Admissions::DeviceRegistrar do
  let(:profile) { create(:organizer_profile) }
  let(:event) { create(:event, :published, organizer_profile: profile, starts_at: 1.day.from_now) }

  it "cannot renew manager-revoked authorization through ordinary registration" do
    device = described_class.call(event: event, user: profile.user, identifier: "qa-device", name: "Gate phone")
    device.revoke!
    revoked_at = device.revoked_at

    expect do
      described_class.call(event: event, user: profile.user, identifier: "qa-device", name: "Renamed phone")
    end.to raise_error(described_class::RegistrationError, /was revoked/)
    expect(device.reload.status_revoked?).to be(true)
    expect(device.revoked_at).to eq(revoked_at)
  end

  it "renews an expired unrevoked device without losing synchronized sequence history" do
    device = described_class.call(event: event, user: profile.user, identifier: "qa-device", name: "Gate phone")
    device.update!(authorization_expires_at: 1.minute.ago, last_sequence: 9)

    renewed = described_class.call(event: event, user: profile.user, identifier: "qa-device", name: "Gate phone")
    expect(renewed.id).to eq(device.id)
    expect(renewed).to be_effective
    expect(renewed.last_sequence).to eq(9)
  end
end
