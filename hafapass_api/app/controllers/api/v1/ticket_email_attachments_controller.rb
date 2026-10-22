# frozen_string_literal: true

require "prawn"

# Serves the PDF attached to a ticket email. The email provider fetches it at
# send time. A ticket that stopped admitting (transfer, refund, dispute,
# cancellation) gets a short notice instead, so the email still delivers
# without carrying a working QR code.
class Api::V1::TicketEmailAttachmentsController < ApplicationController
  skip_before_action :authenticate_user!

  def show
    ticket, current = TicketEmailAttachments.resolve(params[:token])
    return head :not_found unless ticket
    # A HEAD probe learns the link is live without rendering a PDF.
    return head :ok, content_type: "application/pdf" if request.head?

    pdf = current ? ticket_pdf(ticket) : notice_pdf("This ticket is no longer valid",
      "Open HåfaPass and sign in to see its current status.")
    response.headers["Cache-Control"] = "no-store"
    send_data pdf, filename: "hafapass-ticket-#{ticket.id}.pdf", type: "application/pdf", disposition: "attachment"
  end

  private

  def ticket_pdf(ticket)
    TicketPdfGenerator.new(ticket).generate
  rescue TicketPdfGenerator::UnsupportedCharacterError
    notice_pdf("Open your ticket in HåfaPass", "This ticket contains text that cannot be printed. Use the ticket link in this email.")
  end

  def notice_pdf(title, body)
    Prawn::Document.new(page_size: "A5", margin: 40) do |pdf|
      pdf.font_families.update("TicketSans" => {
        normal: TicketPdfGenerator::FONT_DIRECTORY.join("NotoSans-Regular.ttf").to_s,
        bold: TicketPdfGenerator::FONT_DIRECTORY.join("NotoSans-Bold.ttf").to_s
      })
      pdf.font("TicketSans")
      pdf.text "HåfaPass", size: 20, style: :bold
      pdf.move_down 24
      pdf.text title, size: 16, style: :bold
      pdf.move_down 8
      pdf.text body, size: 11
    end.render
  end
end
