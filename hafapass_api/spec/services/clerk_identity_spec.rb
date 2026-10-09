require "rails_helper"

RSpec.describe ClerkIdentity do
  let(:response) do
    double(code: "200", body: {
      id: "user_recipient", email_addresses: [
        { email_address: "TEAM@example.com", verification: { status: "verified" } },
        { email_address: "unverified@example.com", verification: { status: "unverified" } }
      ]
    }.to_json)
  end
  let(:http) { instance_double(Net::HTTP) }

  before do
    allow(ENV).to receive(:[]).and_call_original
    allow(ENV).to receive(:[]).with("CLERK_SECRET_KEY").and_return("sk_test_identity_fixture")
    allow(ENV).to receive(:fetch).and_call_original
    allow(ENV).to receive(:fetch).with("CLERK_SECRET_KEY").and_return("sk_test_identity_fixture")
    allow(Net::HTTP).to receive(:start).and_yield(http)
    allow(http).to receive(:request).and_return(response)
  end

  it "uses the authenticated provider subject and only provider-verified addresses" do
    expect(described_class.verified_email_addresses("user_recipient")).to eq(["team@example.com"])
    expect(http).to have_received(:request).with(have_attributes(path: "/v1/users/user_recipient"))
  end

  it "fails closed when the response subject does not match" do
    expect(described_class.verified_email_addresses("user_other")).to eq([])
  end

  it "fails closed on outages, invalid JSON and missing configuration" do
    allow(http).to receive(:request).and_raise(Net::ReadTimeout)
    expect(described_class.verified_email_addresses("user_recipient")).to eq([])
    allow(http).to receive(:request).and_return(double(code: "200", body: "not json"))
    expect(described_class.verified_email_addresses("user_recipient")).to eq([])
    allow(ENV).to receive(:[]).with("CLERK_SECRET_KEY").and_return(nil)
    expect(described_class.verified_email_addresses("user_recipient")).to eq([])
  end

  it "does not treat an editable contact email as verified ownership" do
    user = build(:user, clerk_id: "user_recipient", email: "unverified@example.com")
    expect(described_class.email_matches?(user: user, email: user.email)).to be(false)
    expect(described_class.email_matches?(user: user, email: "TEAM@example.com")).to be(true)
  end
end
