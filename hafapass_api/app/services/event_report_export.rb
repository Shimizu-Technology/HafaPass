# frozen_string_literal: true

class EventReportExport
  SALES_COLUMNS = {
    ticket_type_name: "Ticket type", tier_name: "Price window", unit_price_cents: "Price paid (cents)",
    tickets_sold: "Tickets sold", tickets_refunded_or_cancelled: "Refunded or cancelled",
    checked_in_count: "Checked in", no_show_count: "Not checked in", gross_cents: "Gross sales (cents)",
    discount_cents: "Discounts (cents)", fee_cents: "Fees charged (cents)", tax_cents: "Tax (cents)",
    refund_cents: "Refunded (cents)", net_cents: "Net sales (cents)",
    organizer_proceeds_cents: "Organizer proceeds (cents)", remaining_capacity: "Remaining ticket type capacity"
  }.freeze
  ATTENDANCE_COLUMNS = [
    "Ticket type", "Expected", "Checked in", "Not checked in", "Check-in rate (%)",
    "30-minute window", "Local time", "Time zone", "Check-ins in window"
  ].freeze
  DEMOGRAPHICS_COLUMNS = [
    "Question", "Asked per", "Answer", "Count", "Share of respondents (%)", "Respondents", "Blank or unanswered"
  ].freeze
  ROSTER_COLUMNS = ["Attendee name", "Attendee email", "Buyer", "Order #", "Ticket type", "Price window",
    "Order status", "Check-in status", "Checked in at"].freeze

  def initialize(report:, report_type:, roster: nil)
    @report = report
    @report_type = report_type
    @roster = roster
  end

  def data
    case @report_type
    when "sales_by_tier"
      [SALES_COLUMNS.values, @report.sales.fetch(:sales_by_tier).map { |row| row.values_at(*SALES_COLUMNS.keys) }]
    when "attendance"
      [ATTENDANCE_COLUMNS, attendance_rows]
    when "demographics"
      [DEMOGRAPHICS_COLUMNS, demographics_rows]
    when "registrations_roster"
      questions = @report.registrations.questions
      [ROSTER_COLUMNS + questions.map { |question| SpreadsheetExport.safe_value(question.prompt) }, roster_rows(questions)]
    end
  end

  private

  def attendance_rows
    attendance = @report.attendance
    counts = [attendance.merge(ticket_type_name: "All tickets"), *attendance.fetch(:by_ticket_type)]
    counts.map { |row| row.values_at(:ticket_type_name, :total_active_tickets, :checked_in_count, :remaining_count, :check_in_rate) } +
      attendance.fetch(:pace).map do |row|
        [nil, nil, nil, nil, nil, row[:bucket_start], row[:label], attendance[:timezone], row[:count]]
      end
  end

  def demographics_rows
    @report.registrations.demographics.flat_map do |question|
      buckets = question.fetch(:buckets).dup
      if question[:other_count].positive?
        buckets << { label: "Other answers", count: question[:other_count],
                     percentage: EventReportingService.percentage(question[:other_count], question[:total_responses]) }
      end
      buckets << {} if buckets.empty?
      buckets.map do |bucket|
        [question[:prompt], question[:scope], *bucket.values_at(:label, :count, :percentage),
          question[:total_responses], question[:blank_or_unanswered_count]]
      end
    end
  end

  def roster_rows(questions)
    Enumerator.new do |rows|
      inline = nil
      @roster.each_batch(on_batch: ->(batch) { inline = EventReportRegistrations::Inline.new(batch) }) do |ticket|
        order = ticket.order
        answers = inline.for_ticket(ticket)
          .index_by { |answer| answer[:question_id] }
        rows << [ticket.attendee_name.presence || order.buyer_name, ticket.holder_email.presence || ticket.attendee_email,
          order.buyer_name, order.reference, ticket.ticket_type.name,
          ticket.order_item&.tier_name.presence || ticket.pricing_tier&.name || "Base price",
          OrganizerTicketSalesStatus.label(order.status), ticket.checked_in? ? "Checked in" : "Not checked in",
          ticket.checked_in_at&.in_time_zone(@report.zone)&.iso8601,
          *questions.map { |question| EventReportRegistrations.display(answers[question.id]&.fetch(:value)) }]
      end
    end
  end
end
