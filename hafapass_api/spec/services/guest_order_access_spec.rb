require "rails_helper"

RSpec.describe GuestOrderAccess do
  let(:order) { create(:order, user: nil) }

  it "issues an order-bound credential and rejects it for other orders" do
    token = described_class.issue!(order)

    expect(described_class.find(token)).to eq(order)
    expect(described_class.find("#{token}tampered")).to be_nil
  end

  it "invalidates prior credentials when access is rotated" do
    old_token = described_class.issue!(order)
    new_token = described_class.issue!(order, rotate: true)

    expect(described_class.find(old_token)).to be_nil
    expect(described_class.find(new_token)).to eq(order)
  end

  it "rejects expired and authenticated-user order credentials" do
    expired = described_class.issue!(order, expires_at: 1.second.ago)
    authenticated_order = create(:order, user: create(:user))
    authenticated = described_class.issue!(authenticated_order)

    expect(described_class.find(expired)).to be_nil
    expect(described_class.find(authenticated)).to be_nil
  end

  it "does not silently restore access when issuing for a revoked order" do
    token = described_class.issue!(order)
    described_class.revoke!(order)

    replacement = described_class.issue!(order)

    expect(described_class.find(token)).to be_nil
    expect(described_class.find(replacement)).to be_nil
    expect(order.reload.guest_access_revoked_at).to be_present

    restored = described_class.issue!(order, rotate: true)
    expect(described_class.find(restored)).to eq(order)
  end

  describe "link lifetime" do
    include ActiveSupport::Testing::TimeHelpers

    it "keeps a link for an event 60 days out working on event day" do
      event = create(:event, :published, starts_at: 60.days.from_now, ends_at: 60.days.from_now + 4.hours)
      far_order = create(:order, event: event, user: nil)
      token = described_class.issue!(far_order)

      travel_to(event.starts_at) { expect(described_class.find(token)).to eq(far_order) }
      travel_to(event.ends_at + 6.days) { expect(described_class.find(token)).to eq(far_order) }
      travel_to(event.ends_at + 8.days) { expect(described_class.find(token)).to be_nil }
    end

    it "lasts at least 30 days for events that are sooner or already over" do
      soon = create(:order, user: nil, event: create(:event, :published, starts_at: 2.days.from_now))

      expect(described_class.default_expires_at(soon)).to be_within(1.second).of(30.days.from_now)
    end

    it "never shortens access that an earlier link granted" do
      long_lived = described_class.issue!(order, expires_at: 90.days.from_now)
      described_class.issue!(order, expires_at: 1.day.from_now)

      expect(order.reload.guest_access_expires_at).to be_within(1.second).of(90.days.from_now)
      travel_to(10.days.from_now) { expect(described_class.find(long_lived)).to eq(order) }
    end
  end
end
