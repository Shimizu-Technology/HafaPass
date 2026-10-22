require "rails_helper"

RSpec.describe MessageAddressFailure do
  it "does not treat bare mailbox or recipient wording as an invalid address" do
    ["mailbox", "recipient", "mailbox temporarily unavailable", "recipient rate limited",
      "Mailbox full", "mailbox over-quota", "quota exceeded"].each do |message|
      expect(described_class.invalid?(message: message)).to be(false), message
    end
  end

  it "still recognizes address-specific failures" do
    ["Mailbox does not exist", "recipient not found", "invalid recipient", "email address is invalid"].each do |message|
      expect(described_class.invalid?(message: message)).to be(true), message
    end
  end
end
