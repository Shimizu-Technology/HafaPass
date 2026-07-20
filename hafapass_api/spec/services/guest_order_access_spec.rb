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
end
