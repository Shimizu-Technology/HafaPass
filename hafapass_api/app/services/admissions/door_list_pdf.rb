# frozen_string_literal: true

require "prawn"
require "prawn/table"

module Admissions
  class DoorListPdf
    def initialize(event, tickets: nil)
      @event = event
      @tickets = tickets
    end

    def generate
      table_rows = rows
      Prawn::Document.new(page_size: "LETTER", margin: 36) do |pdf|
        # Attendee, event and ticket names can be in any supported language.
        configure_fonts(pdf, table_rows)
        pdf.text @tickets ? "HåfaPass door list" : "HåfaPass emergency door list", size: 18, style: :bold, color: "0D9488"
        pdf.move_down 6
        pdf.text @title || event.title, size: 14, style: :bold
        pdf.text @details || event_details, size: 9, color: "4B5563"
        pdf.move_down 12
        guidance = @tickets ? "Mark check-ins and reconcile them with the scanner afterward." :
          "Use only during a scanner outage; record every admission and reconcile it afterward."
        pdf.text "Generated #{Time.current.in_time_zone(event.timezone).strftime("%Y-%m-%d %-I:%M %p %Z")}. #{guidance}",
          size: 8, color: "6B7280"
        pdf.move_down 12
        pdf.table(table_rows, header: true, width: pdf.bounds.width, cell_style: { size: 8, padding: 5 }) do |table|
          table.row(0).font_style = :bold
          table.row(0).background_color = "E5E7EB"
          table.columns(0).width = @tickets ? 175 : 72
          table.columns(3).width = 70
        end
        pdf.number_pages "Page <page> of <total>", at: [pdf.bounds.left, 0], align: :center, size: 7
      end.render
    end

    private

    attr_reader :event

    def rows
      source = @tickets || event.tickets.includes(:ticket_type,
        event_seat: { venue_seat: { seating_row: :seating_section } }).order(:attendee_name, :id)
      if @tickets
        [["Attendee", "Type", "Order #", "Check in"]] + source.map do |ticket|
          [ticket.attendee_name.presence || "Guest", ticket.ticket_type.name, ticket.order.reference, "________"]
        end
      else
        [["Ticket", "Attendee", "Type", "Status", "Door mark"]] + source.map do |ticket|
          ["HP-T#{ticket.id}", ticket.attendee_name.presence || "Guest",
            [ticket.ticket_type.name, ticket.seat_label].compact.join(" · "), ticket.status.humanize, "________"]
        end
      end
    end

    # An emergency list must always print, so a character no bundled font can
    # draw (a rare script) is shown as "?" instead of stopping the download.
    def configure_fonts(pdf, table_rows)
      unsupported = PdfFonts.configure(pdf, texts: [event.title, event_details, *table_rows.flatten], strict: false)
      return if unsupported.empty?

      pattern = Regexp.union(unsupported)
      table_rows.each { |row| row.map! { |value| value.to_s.gsub(pattern, "?") } }
      @title = event.title.to_s.gsub(pattern, "?")
      @details = event_details.gsub(pattern, "?")
    end

    def event_details
      local_start = event.starts_at&.in_time_zone(event.timezone)
      [local_start&.strftime("%A, %B %-d, %Y %-I:%M %p %Z"), event.venue_name].compact.join(" · ")
    end
  end
end
