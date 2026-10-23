# frozen_string_literal: true

require "rails_helper"

RSpec.describe AuditSanitizer do
  it "scrubs TINs, card numbers, bearer credentials and secrets recursively" do
    clean = described_class.call({ note: "TIN 123-45-6789", reason: "account 123456789",
      card_number: "4111 1111 1111 1111", innocent: "card 4242-4242-4242-4242",
      nested: [{ access_token: "private", value: "Bearer private", password: "secret", plain: 4111111111111111 }],
      tin_last_four: "6789", amount_cents: 1500 })
    expect(clean.to_json).not_to include("123-45-6789", "123456789", "4111", "4242", "private", "secret")
    expect(clean).to include("tin_last_four" => "6789", "amount_cents" => 1500)
  end

  it "removes verification URL credentials, query and fragment, including nested diffs" do
    clean = described_class.call({ verification_link: { before: "https://example.com/id?token=private#private",
      after: "https://user:pass@example.com/new?x=private" } })
    expect(clean["verification_link"]).to eq("before" => "https://example.com/id", "after" => "https://example.com/new")
  end

  it "records search usage and bounds provider messages" do
    clean = described_class.call({ filters: { search: "buyer@example.com", q: "buyer" }, message: "x" * 2000 })
    expect(clean["filters"]).to eq("search_used" => true)
    expect(clean.to_json).not_to include("buyer")
    expect(clean["message"].length).to be <= 500
  end

  it "preserves typed monetary and identity numbers while rejecting numeric tax fields" do
    expect(described_class.call({ amount_cents: 123456789, event_id: 123456789, tax_id: 123456789 }))
      .to eq("amount_cents" => 123456789, "event_id" => 123456789, "tax_id" => "[redacted]")
  end
end
