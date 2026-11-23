require "rails_helper"

RSpec.describe EventTimeParser do
  it "interprets an offset-free datetime as a Pacific/Guam wall time" do
    parsed = described_class.call("2026-08-15T19:00", timezone: "Pacific/Guam")

    expect(parsed).to eq(Time.utc(2026, 8, 15, 9, 0))
    expect(parsed.in_time_zone("Pacific/Guam").strftime("%F %R")).to eq("2026-08-15 19:00")
  end

  it "uses the supplied event timezone for UTC and US-Pacific wall times" do
    input = "2026-08-15T19:00:01"

    expect(described_class.call(input, timezone: "UTC")).to eq(Time.utc(2026, 8, 15, 19, 0, 1))
    expect(described_class.call(input, timezone: "America/Los_Angeles")).to eq(Time.utc(2026, 8, 16, 2, 0, 1))
  end

  it "preserves the instant supplied by an ISO 8601 offset" do
    parsed = described_class.call("2026-08-15T19:00:00+10:00", timezone: "Pacific/Guam")

    expect(parsed).to eq(Time.utc(2026, 8, 15, 9, 0))
  end

  it "keeps offset-free fractional seconds in the event timezone" do
    parsed = described_class.call("2027-05-01T23:59:01.123456", timezone: "Pacific/Guam")

    expect(parsed.iso8601(6)).to eq("2027-05-01T13:59:01.123456Z")
  end

  it "rejects a skipped local hour at the start of Pacific daylight saving" do
    expect {
      described_class.call("2027-03-14T02:30", timezone: "America/Los_Angeles")
    }.to raise_error(described_class::ParseError, /Choose a valid date and time/)
  end

  it "rejects invalid values" do
    expect {
      described_class.call("not-a-date", timezone: "Pacific/Guam")
    }.to raise_error(described_class::ParseError)
  end
end
