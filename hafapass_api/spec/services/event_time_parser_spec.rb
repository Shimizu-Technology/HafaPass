require "rails_helper"

RSpec.describe EventTimeParser do
  it "interprets an offset-free datetime as a Pacific/Guam wall time" do
    parsed = described_class.call("2026-08-15T19:00", timezone: "Pacific/Guam")

    expect(parsed).to eq(Time.utc(2026, 8, 15, 9, 0))
    expect(parsed.in_time_zone("Pacific/Guam").strftime("%F %R")).to eq("2026-08-15 19:00")
  end

  it "preserves the instant supplied by an ISO 8601 offset" do
    parsed = described_class.call("2026-08-15T19:00:00+10:00", timezone: "Pacific/Guam")

    expect(parsed).to eq(Time.utc(2026, 8, 15, 9, 0))
  end

  it "rejects invalid values" do
    expect {
      described_class.call("not-a-date", timezone: "Pacific/Guam")
    }.to raise_error(described_class::ParseError)
  end
end
