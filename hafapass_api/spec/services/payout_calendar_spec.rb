# frozen_string_literal: true

require "rails_helper"

RSpec.describe PayoutCalendar do
  def guam(*args) = ActiveSupport::TimeZone["Pacific/Guam"].local(*args)

  it "lists 2027 bank holidays, moving Sunday holidays to Monday and leaving Saturday ones alone" do
    holidays = described_class.holidays(2027)
    expect(holidays).to include(
      Date.new(2027, 1, 1) => "New Year's Day",
      Date.new(2027, 1, 18) => "Martin Luther King Jr. Day",
      Date.new(2027, 2, 15) => "Presidents' Day",
      Date.new(2027, 3, 1) => "Guam History and Chamorro Heritage Day",
      Date.new(2027, 3, 26) => "Good Friday",
      Date.new(2027, 5, 31) => "Memorial Day",
      Date.new(2027, 7, 5) => "Independence Day",
      Date.new(2027, 7, 21) => "Liberation Day",
      Date.new(2027, 11, 25) => "Thanksgiving Day",
      Date.new(2027, 12, 8) => "Our Lady of Camarin Day"
    )
    # Juneteenth 2027 is a Saturday: banks are open Friday the 18th.
    expect(holidays).not_to have_key(Date.new(2027, 6, 18))
    expect(described_class.business_day?(Date.new(2027, 6, 18))).to be(true)
    expect(described_class.holidays(2026)).to include(Date.new(2026, 11, 26) => "Thanksgiving Day",
      Date.new(2026, 4, 3) => "Good Friday")
  end

  it "counts 2–3 business days after a Saturday event, skipping weekends and holidays" do
    saturday = Date.new(2027, 1, 30)
    expect(described_class.add_business_days(saturday, 2)).to eq(Date.new(2027, 2, 2))
    expect(described_class.add_business_days(saturday, 3)).to eq(Date.new(2027, 2, 3))
    # Friday before Presidents' Day weekend.
    expect(described_class.add_business_days(Date.new(2027, 2, 12), 3)).to eq(Date.new(2027, 2, 18))
    # Over the Guam History and Chamorro Heritage Day Monday.
    expect(described_class.add_business_days(Date.new(2027, 2, 26), 1)).to eq(Date.new(2027, 3, 2))
    expect(described_class.business_days_between(Date.new(2027, 2, 3), Date.new(2027, 2, 8))).to eq(3)
    expect(described_class.business_days_between(Date.new(2027, 2, 8), Date.new(2027, 2, 3))).to eq(0)
    expect { described_class.add_business_days(saturday, 0) }.to raise_error(ArgumentError)
  end

  it "reads dates in Guam time, not UTC" do
    event = build(:event, timezone: "Pacific/Guam")
    # 6 a.m. Sunday in Guam is still Saturday in UTC.
    early_sunday = guam(2027, 1, 31, 6)
    expect(early_sunday.utc.to_date).to eq(Date.new(2027, 1, 30))
    expect(described_class.local_date(early_sunday, event)).to eq(Date.new(2027, 1, 31))
    expect(described_class.local_date(guam(2027, 1, 30, 23, 59), event)).to eq(Date.new(2027, 1, 30))
    expect(described_class.timezone_for(build(:event, timezone: nil)).tzinfo.name).to eq("Pacific/Guam")
  end
end
