# frozen_string_literal: true

require "prawn"
require "prawn/table"

module Admissions
  class DoorListPdf
    def initialize(event)
      @event = event
    end

    def generate
      Prawn::Document.new(page_size: "LETTER", margin: 36) do |pdf|
        pdf.font "Helvetica"
        pdf.text "HafaPass emergency door list", size: 18, style: :bold, color: "0D9488"
        pdf.move_down 6
        pdf.text event.title, size: 14, style: :bold
        pdf.text event_details, size: 9, color: "4B5563"
        pdf.move_down 12
        pdf.text "Generated #{Time.current.in_time_zone(event.timezone).strftime("%Y-%m-%d %-I:%M %p %Z")}. " \
          "Use only during a scanner outage; record every admission and reconcile it afterward.", size: 8, color: "6B7280"
        pdf.move_down 12
        pdf.table(rows, header: true, width: pdf.bounds.width, cell_style: { size: 8, padding: 5 }) do |table|
          table.row(0).font_style = :bold
          table.row(0).background_color = "E5E7EB"
          table.columns(0).width = 72
          table.columns(3).width = 70
        end
        pdf.number_pages "Page <page> of <total>", at: [pdf.bounds.left, 0], align: :center, size: 7
      end.render
    end

    private

    attr_reader :event

    def rows
      [["Ticket", "Attendee", "Type", "Status", "Door mark"]] +
        event.tickets.includes(:ticket_type).order(:attendee_name, :id).map do |ticket|
          ["HP-T#{ticket.id}", safe_text(ticket.attendee_name.presence || "Guest"), safe_text(ticket.ticket_type.name),
            ticket.status.humanize, "________"]
        end
    end

    def event_details
      local_start = event.starts_at&.in_time_zone(event.timezone)
      [local_start&.strftime("%A, %B %-d, %Y %-I:%M %p %Z"), event.venue_name].compact.join(" · ")
    end

    def safe_text(value)
      value.to_s.encode("Windows-1252", invalid: :replace, undef: :replace, replace: "?")
    end
  end
end
