# frozen_string_literal: true

require "csv"

# Multi-section UTF-8 BOM CSV export for an EventSeriesReport.
# Every cell passes through SpreadsheetExport.safe_value for formula-injection
# protection, while formatted currency amounts use SpreadsheetExport::Amount
# (via FinanceExports.money) so spreadsheets interpret numbers accurately.
class EventSeriesReportExport
  UTF8_BOM = "\uFEFF"

  GROUP_LABELS = [
    [:admissions, "Admissions (Regular Nights, Championship Nights & Passes)"],
    [:registration, "Team Registration"],
    [:other, "Other"],
    [:combined, "Combined Series Total"]
  ].freeze

  CHANNEL_ORDER = %i[online_stripe door_cash free_comp].freeze

  def self.to_csv(report)
    new(report).to_csv
  end

  def self.safe_filename(event_series)
    raw = event_series.slug.presence || event_series.name.to_s.parameterize
    sanitized = raw.to_s.gsub(/[^a-zA-Z0-9_-]/, "-").gsub(/-+/, "-").gsub(/\A-|-\z/, "")
    prefix = sanitized.presence || "series-#{event_series.id}"
    "#{prefix}-series-report.csv"
  end

  def initialize(report)
    @report = report
    @currency = report.fetch(:currency, "usd").to_s.upcase
  end

  def to_csv
    lines = rows.map do |row|
      CSV.generate_line(row.map { |value| SpreadsheetExport.safe_value(value) }, force_quotes: true)
    end
    UTF8_BOM + lines.join
  end

  def rows
    summary_section + [[]] +
      groups_section + [[]] +
      channels_section + [[]] +
      events_section + [[]] +
      ticket_types_section
  end

  private

  attr_reader :report, :currency

  def summary_section
    series = report.fetch(:series)
    org = report.fetch(:organization)
    share = report.fetch(:revenue_share)
    checklist = report.fetch(:closeout_checklist)

    [
      ["SECTION 1: SERIES SUMMARY & REVENUE-SHARE WORKSHEET"],
      ["Field", "Value", "Notes"],
      ["Series", series[:name], "Slug: #{series[:slug]} | Status: #{series[:status]}"],
      ["Organization", org[:name], "Currency: #{currency}"],
      ["Generated At", report[:generated_at]&.iso8601, "Read-only financial report"],
      ["Events in Series", series[:events_count], ""],
      ["Revenue-Share Base Formula", share[:revenue_share_base], ""],
      ["Door Cash Included in Base", share[:revenue_share_includes_door_cash] ? "Yes" : "No", ""],
      ["Revenue-Share Base Amount", money(share[:base_cents]), currency],
      [share[:revenue_share_label], money(share[:share_cents]), format_bps(share[:revenue_share_bps])],
      [share[:primary_share_label], money(share[:primary_cents]), format_bps(share[:primary_share_bps])],
      ["Door Cash Retained by Organizer", money(share[:door_cash_retained_cents]), "Kept at door; excluded from platform payouts"],
      ["Net Platform Payable", money(share[:net_platform_payable_cents]), currency],
      ["Paid Out", money(share[:paid_cents]), currency],
      ["Remaining Owed", money(share[:owed_cents]), currency],
      ["Reserves Held", money(share[:reserve_cents]), "#{checklist[:active_reserve_count]} event(s) with active reserves"],
      ["Check Reference Pattern", checklist[:check_reference_pattern], checklist[:guidance]]
    ]
  end

  def groups_section
    groups = report.fetch(:groups)
    header = [
      "Group", "Events", "Tickets Issued", "Direct Paid Tickets", "Free Tickets", "Pass Child Tickets",
      "Checked In", "Gross", "Discounts", "Refunds", "Platform Fees", "Processing Fees (Organizer)",
      "Processing Fees (Platform)", "Organizer Proceeds", "Door Cash Retained", "Reserves Held",
      "Other Adjustments", "Balance", "Platform Payable", "Paid Out", "In Flight", "Held",
      "Remaining Owed", "Negative Balance", "Currency"
    ]

    data = GROUP_LABELS.map do |key, label|
      row = groups.fetch(key)
      [
        label,
        row[:events_count],
        row[:tickets_issued_count],
        row[:direct_paid_tickets_count],
        row[:free_tickets_count],
        row[:pass_child_tickets_count],
        row[:checked_in_count],
        money(row[:gross_cents]),
        money(row[:discount_cents]),
        money(row[:refund_cents]),
        money(row[:platform_fee_cents]),
        money(row[:processing_fee_cents]),
        money(row[:platform_processing_fee_cents]),
        money(row[:organizer_proceeds_cents]),
        money(row[:door_cash_retained_cents]),
        money(row[:reserve_cents]),
        money(row[:other_adjustment_cents]),
        money(row[:balance_cents]),
        money(row[:payable_cents]),
        money(row[:paid_cents]),
        money(row[:in_flight_cents]),
        money(row[:held_cents]),
        money(row[:owed_cents]),
        money(row[:negative_balance_cents]),
        currency
      ]
    end

    [["SECTION 2: GROUP SUBTOTALS"], header] + data
  end

  def channels_section
    channels = report.fetch(:channels)
    header = [
      "Channel", "Orders", "Tickets Issued", "Checked In", "Gross", "Discounts",
      "Refunds", "Organizer Proceeds", "Door Cash Retained", "Currency"
    ]

    data = CHANNEL_ORDER.map do |key|
      row = channels.fetch(key)
      [
        row[:label],
        row[:orders_count],
        row[:tickets_issued_count],
        row[:checked_in_count],
        money(row[:gross_cents]),
        money(row[:discount_cents]),
        money(row[:refund_cents]),
        money(row[:organizer_proceeds_cents]),
        money(row[:door_cash_retained_cents]),
        currency
      ]
    end

    [["SECTION 3: CHANNEL BREAKDOWN"], header] + data
  end

  def events_section
    header = [
      "Event ID", "Event", "Role", "Status", "Starts At", "Ends At",
      "Tickets Issued", "Direct Paid", "Free", "Pass Child", "Checked In",
      "Gross", "Discounts", "Refunds", "Platform Fees", "Processing Fees (Organizer)",
      "Processing Fees (Platform)", "Organizer Proceeds", "Door Cash Retained",
      "Reserves Held", "Other Adjustments", "Balance", "Platform Payable",
      "Paid Out", "In Flight", "Held", "Remaining Owed",
      "Settlement State", "Payout State", "Closeout Note", "Currency"
    ]

    data = report.fetch(:events).map do |row|
      [
        row[:event_id],
        row[:title],
        row[:role],
        row[:status],
        format_event_time(row[:starts_at], row[:timezone]),
        format_event_time(row[:ends_at], row[:timezone]),
        row[:tickets_issued_count],
        row[:direct_paid_tickets_count],
        row[:free_tickets_count],
        row[:pass_child_tickets_count],
        row[:checked_in_count],
        money(row[:gross_cents]),
        money(row[:discount_cents]),
        money(row[:refund_cents]),
        money(row[:platform_fee_cents]),
        money(row[:processing_fee_cents]),
        money(row[:platform_processing_fee_cents]),
        money(row[:organizer_proceeds_cents]),
        money(row[:door_cash_retained_cents]),
        money(row[:reserve_cents]),
        money(row[:other_adjustment_cents]),
        money(row[:balance_cents]),
        money(row[:payable_cents]),
        money(row[:paid_cents]),
        money(row[:in_flight_cents]),
        money(row[:held_cents]),
        money(row[:owed_cents]),
        row[:settlement_state],
        row[:payout_state],
        row[:closeout_note],
        currency
      ]
    end

    [["SECTION 4: PER-EVENT BREAKDOWN"], header] + data
  end

  def ticket_types_section
    header = [
      "Event ID", "Event", "Role", "Ticket Type", "Pricing Tier", "Unit Price",
      "Tickets Issued", "Checked In", "Gross", "Discounts", "Refunded Proceeds",
      "Organizer Proceeds", "Currency"
    ]

    data = report.fetch(:ticket_types).map do |row|
      [
        row[:event_id],
        row[:event_title],
        row[:role],
        row[:ticket_type_name],
        row[:pricing_tier_name],
        money(row[:price_cents]),
        row[:tickets_issued_count],
        row[:checked_in_count],
        money(row[:gross_cents]),
        money(row[:discount_cents]),
        money(row[:refunded_proceeds_cents]),
        money(row[:organizer_proceeds_cents]),
        currency
      ]
    end

    [["SECTION 5: TICKET-TYPE BREAKDOWN"], header] + data
  end

  def money(cents)
    FinanceExports.money(cents)
  end

  def format_bps(bps)
    format("%.2f%%", bps.to_i / 100.0)
  end

  def format_event_time(value, timezone)
    return nil unless value

    tz = ActiveSupport::TimeZone[timezone.to_s] || Time.zone
    value.in_time_zone(tz).iso8601
  end
end
