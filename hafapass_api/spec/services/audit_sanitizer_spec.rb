# frozen_string_literal: true

require "rails_helper"

RSpec.describe AuditSanitizer do
  let(:regression_uuid) { "0b79eff1-9b1c-4325-9816-76772f045585" }

  it "preserves the scanner recovery UUID as a value and an action_uuids element" do
    expect(described_class.call(regression_uuid)).to eq(regression_uuid)
    expect(described_class.call({ action_uuids: [regression_uuid] })).to eq("action_uuids" => [regression_uuid])
  end

  it "preserves 5,000 seeded UUIDs and digit-heavy UUIDs, standalone and embedded" do
    random = Random.new(20261027)
    uuids = Array.new(5000) do |index|
      hex = random.bytes(16).unpack1("H*")
      uuid = [hex[0, 8], hex[8, 4], hex[12, 4], hex[16, 4], hex[20, 12]].join("-")
      index.even? ? uuid : uuid.upcase
    end
    uuids.concat([regression_uuid, "00000000-0000-0000-0000-000000000000",
      "12345678-1234-1234-1234-123456789012", "99999999-9999-9999-9999-999999999999",
      "ABCDEF12-3456-7890-1234-567890123456"])

    uuids.each do |uuid|
      text = "Recovered #{uuid}; retry (#{uuid})"
      expect(described_class.call(uuid)).to eq(uuid), "standalone UUID: #{uuid}"
      expect(described_class.call(text)).to eq(text), "embedded UUID: #{uuid}"
      expect(described_class.call(uuid, key: :message)).to eq(uuid), "free-text UUID: #{uuid}"
      expect(described_class.call(text, key: :message)).to eq(text), "embedded free-text UUID: #{uuid}"
    end
  end

  it "redacts numeric PII and credentials next to UUIDs without corrupting the identifiers" do
    pii = ["123-45-6789", "12-3456789", "123456789", "4111 1111 1111 1111", "4242-4242-4242-4242",
      "sk_live_example", "Bearer private", "eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxMjMifQ.signature",
      "token=private", "secret: private", "password=private", "api_key=private"]

    pii.each do |value|
      expect(described_class.call(value)).to eq("[redacted]")
      expect(described_class.call("#{regression_uuid} #{value}\n#{regression_uuid}"))
        .to eq("#{regression_uuid} [redacted]\n#{regression_uuid}")
      expect(described_class.call("#{value} #{regression_uuid}")).to include("[redacted]", regression_uuid)
      expect(described_class.call("#{regression_uuid} #{value}")).to include("[redacted]", regression_uuid)
    end
  end

  it "redacts numeric PII touching UUIDs on either side" do
    %w[123-45-6789 12-3456789 123456789 4111111111111111 4242-4242-4242-4242].each do |value|
      expect(described_class.call("#{value}#{regression_uuid}")).to eq("[redacted]#{regression_uuid}")
      expect(described_class.call("#{regression_uuid}#{value}")).to eq("#{regression_uuid}[redacted]")
    end
  end

  it "still rejects sensitive UUID fields and credentials whose value is a UUID" do
    %i[secret access_token password tin ssn tax_id taxpayer_id tax_information_tin account_number].each do |key|
      expect(described_class.call(regression_uuid, key: key)).to eq("[redacted]")
    end
    expect(described_class.call("Bearer #{regression_uuid}")).to eq("[redacted]")
    expect(described_class.call("token=#{regression_uuid}")).to eq("[redacted]")
  end

  it "retains free-text rejection, URL stripping and truncation around UUIDs" do
    expect(described_class.call("#{regression_uuid} SSN 123-45-6789", key: :note)).to eq("[redacted]")
    expect(described_class.call("#{regression_uuid} EIN 12-3456789", key: :reason)).to eq("[redacted]")
    expect(described_class.call("https://user:pass@example.com/#{regression_uuid}?id=#{regression_uuid}#private"))
      .to eq("https://example.com/#{regression_uuid}")
    text = "#{regression_uuid} #{'x' * 1000}"
    expect(described_class.call(text)).to eq(text.truncate(500))
  end

  it "preserves generated export UUIDs even when they contain long numeric runs" do
    uuid = "12345678-1234-4123-8123-123456789012"
    expect(described_class.call({ export_request_id: uuid })).to eq("export_request_id" => uuid)
    expect(described_class.call({ secret: uuid })).to eq("secret" => "[redacted]")
    expect(described_class.call({ export_request_id: "123456789" })).to eq("export_request_id" => "[redacted]")
  end

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
