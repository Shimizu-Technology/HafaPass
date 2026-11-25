# frozen_string_literal: true

# Business days for organizer bank transfers, in the event's local calendar
# (Guam unless the event says otherwise). A business day is a weekday that is
# not a bank holiday: the Federal Reserve holidays US banks close for, plus the
# Guam public holidays local banks close for. A holiday on a Sunday closes
# banks the following Monday; one on a Saturday closes nothing extra (the
# Federal Reserve rule: banks stay open the Friday before).
#
# This sets an operating target for finance, not a legal deadline. Finance
# should confirm the list against the bank's own calendar each year.
module PayoutCalendar
  DEFAULT_TIMEZONE = "Pacific/Guam"

  module_function

  def timezone_for(event)
    ActiveSupport::TimeZone[event&.timezone.to_s] || ActiveSupport::TimeZone[DEFAULT_TIMEZONE]
  end

  def local_date(time, event)
    time&.in_time_zone(timezone_for(event))&.to_date
  end

  def today(event, at: Time.current)
    local_date(at, event)
  end

  def business_day?(date)
    !date.saturday? && !date.sunday? && !holiday?(date)
  end

  def holiday?(date)
    holidays(date.year).key?(date)
  end

  # The nth business day after date (date itself never counts).
  def add_business_days(date, count)
    raise ArgumentError, "count must be positive" unless count.positive?

    current = date
    remaining = count
    while remaining.positive?
      current += 1
      remaining -= 1 if business_day?(current)
    end
    current
  end

  # Business days strictly after from, up to and including to. Zero when to is
  # on or before from.
  def business_days_between(from, to)
    return 0 if to <= from

    ((from + 1)..to).count { |date| business_day?(date) }
  end

  # { Date => "Holiday name" } for one year, with Sunday holidays moved to the
  # Monday banks observe them.
  def holidays(year)
    @holidays ||= {}
    @holidays[year] ||= named_holidays(year).each_with_object({}) do |(name, date), list|
      list[observed(date)] ||= name
    end.freeze
  end

  def named_holidays(year)
    {
      "New Year's Day" => Date.new(year, 1, 1),
      "Martin Luther King Jr. Day" => nth_weekday(year, 1, 1, 3),
      "Presidents' Day" => nth_weekday(year, 2, 1, 3),
      "Guam History and Chamorro Heritage Day" => nth_weekday(year, 3, 1, 1),
      "Good Friday" => easter(year) - 2,
      "Memorial Day" => last_weekday(year, 5, 1),
      "Juneteenth" => Date.new(year, 6, 19),
      "Independence Day" => Date.new(year, 7, 4),
      "Liberation Day" => Date.new(year, 7, 21),
      "Labor Day" => nth_weekday(year, 9, 1, 1),
      "Columbus Day" => nth_weekday(year, 10, 1, 2),
      "All Souls' Day" => Date.new(year, 11, 2),
      "Veterans Day" => Date.new(year, 11, 11),
      "Thanksgiving Day" => nth_weekday(year, 11, 4, 4),
      "Our Lady of Camarin Day" => Date.new(year, 12, 8),
      "Christmas Day" => Date.new(year, 12, 25)
    }
  end

  def observed(date)
    date.sunday? ? date + 1 : date
  end

  # wday: 0 Sunday … 6 Saturday.
  def nth_weekday(year, month, wday, nth)
    first = Date.new(year, month, 1)
    first + ((wday - first.wday) % 7) + (7 * (nth - 1))
  end

  def last_weekday(year, month, wday)
    last = Date.new(year, month, -1)
    last - ((last.wday - wday) % 7)
  end

  # Anonymous Gregorian algorithm.
  def easter(year)
    a = year % 19
    b, c = year.divmod(100)
    d, e = b.divmod(4)
    f = (b + 8) / 25
    g = (b - f + 1) / 3
    h = ((19 * a) + b - d - g + 15) % 30
    i, k = c.divmod(4)
    l = (32 + (2 * e) + (2 * i) - h - k) % 7
    m = (a + (11 * h) + (22 * l)) / 451
    month, day = (h + l - (7 * m) + 114).divmod(31)
    Date.new(year, month, day + 1)
  end
end
