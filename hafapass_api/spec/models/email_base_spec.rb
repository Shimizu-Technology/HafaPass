require "rails_helper"

RSpec.describe "Email audience models" do
  it "normalizes unique subscribers and bounds preferences without inventing consent" do
    first = PlatformSubscriber.create!(email: "UPPER@example.test", source: "footer")
    expect(first.email).to eq("upper@example.test")
    expect(first.status).to eq("pending")
    expect(PlatformSubscriber.new(email: first.email, source: "home")).not_to be_valid
    expect(PlatformSubscriber.new(email: "new@example.test", source: "unknown")).not_to be_valid
    expect(PlatformSubscriber.new(email: "new@example.test", source: "home", interests: ["x" * 81])).not_to be_valid
    expect(PlatformSubscriber.new(email: "new@example.test", source: "home", status: "anything")).not_to be_valid
  end

  it "keeps consent records append-only" do
    ledger = EmailConsent.record!(email: "TEST@example.test", scope: "platform", action: "requested", source: "footer")
    expect(ledger.email).to eq("test@example.test")
    expect(ledger.update(action: "confirmed")).to be(false)
    expect(ledger.destroy).to be(false)
    expect(ledger.reload.action).to eq("requested")
  end

  it "rejects mixed platform and organizer campaign scopes and unsafe subjects" do
    user = create(:user, role: :admin)
    mailing = AudienceMailing.new(created_by: user, subject: "A\nB", body: "Body", audience: "buyers")
    expect(mailing).not_to be_valid
    mailing.assign_attributes(subject: "Events", audience: "platform")
    expect(mailing).to be_valid
    mailing.organization = create(:organization)
    expect(mailing).not_to be_valid
  end
end
