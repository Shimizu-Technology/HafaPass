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
  it "authorizes membership-free platform admins within the event and hard limits" do
    admin = create(:user, :admin)
    device = described_class.call(event: event, user: admin, identifier: "admin", name: "Admin phone")
    expect(device).to be_effective
    expect(device.authorization_expires_at).to be <= 24.hours.from_now
    expect(device.authorization_expires_at).to be <= (event.ends_at || event.starts_at) + 12.hours
  end

  it "ends a device lease with the effective access path and event window" do
    staff = create(:user)
    membership = create(:organization_membership, organization: event.organization, user: staff, role: :scanner,
      expires_at: 2.hours.from_now)
    assignment = create(:event_staff_assignment, event: event, user: staff, role: :scanner, expires_at: 1.hour.from_now)
    device = described_class.call(event: event, user: staff, identifier: "leased", name: "Gate phone")
    expect(device.authorization_expires_at).to be_within(1.second).of(assignment.expires_at)
    assignment.update!(expires_at: nil)
    renewed = described_class.call(event: event, user: staff, identifier: "leased", name: "Gate phone")
    expect(renewed.authorization_expires_at).to be_within(1.second).of(membership.expires_at)
  end
end
