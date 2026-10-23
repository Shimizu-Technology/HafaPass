require "rails_helper"
require "pdf/reader"

RSpec.describe "Ticket email PDF attachments", type: :request do
  include ActiveSupport::Testing::TimeHelpers

  before { stub_const("ENV", ENV.to_h.merge("PUBLIC_API_URL" => "https://api.hafapass.test")) }

  let(:ticket) { wallet_ticket }

  def attachment_path(attachment)
    URI.parse(attachment.fetch(:path)).path
  end

  def pdf_text(body)
    PDF::Reader.new(StringIO.new(body)).pages.map(&:text).join("\n")
  end

  it "links a signed, expiring PDF for a ticket that admits" do
    attachment = TicketEmailAttachments.for([ticket]).sole
    expect(attachment[:filename]).to eq("hafapass-ticket-#{ticket.id}.pdf")
    expect(attachment[:path]).to start_with("https://api.hafapass.test/api/v1/ticket_email_attachments/")

    get attachment_path(attachment)
    expect(response).to have_http_status(:ok)
    expect(response.media_type).to eq("application/pdf")
    expect(response.headers["Cache-Control"]).to include("no-store")
    expect(pdf_text(response.body)).to include(ticket.event.title)

    travel_to(TicketEmailAttachments::TTL.from_now + 1.minute) do
      get attachment_path(attachment)
      expect(response).to have_http_status(:not_found)
    end
  end

  it "never links a PDF for refunded, disputed, pending-refund or cancelled tickets" do
    refunded = wallet_ticket(status: :refunded)
    disputed = wallet_ticket
    Dispute.create!(order: disputed.order, provider: "stripe", provider_dispute_id: "dp_attach", currency: "usd",
      opened_at: Time.current, amount_cents: 100, status: :open)
    pending = wallet_ticket
    create(:refund, order: pending.order, status: :pending, succeeded_at: nil, amount_cents: pending.order.total_cents)
    cancelled = wallet_ticket
    cancelled.update!(status: :cancelled, cancelled_at: Time.current)

    expect(TicketEmailAttachments.for([refunded, disputed.reload, pending.reload, cancelled])).to eq([])
  end

  it "serves a notice instead of the ticket once the ticket is transferred or blocked after sending" do
    attachment = TicketEmailAttachments.for([ticket]).sole
    ticket.update!(display_credential_version: ticket.display_credential_version + 1,
      scan_credential_version: ticket.scan_credential_version + 1)

    get attachment_path(attachment)
    expect(response).to have_http_status(:ok)
    text = pdf_text(response.body)
    expect(text).to include("This ticket is no longer valid")
    expect(text).not_to include(ticket.event.title)
  end

  it "serves the notice after a holder-only QR refresh, so a leaked link never yields the new code" do
    attachment = TicketEmailAttachments.for([ticket]).sole
    ticket.rotate_scan_credential!

    get attachment_path(attachment)
    text = pdf_text(response.body)
    expect(text).to include("This ticket is no longer valid")
    expect(text).not_to include(ticket.event.title)
  end

  it "serves the notice once the ticket has a different holder account" do
    attachment = TicketEmailAttachments.for([ticket]).sole
    ticket.update!(holder_user: create(:user))

    get attachment_path(attachment)
    expect(pdf_text(response.body)).to include("This ticket is no longer valid")
  end

  it "limits each signed link on its own, not by the provider's shared fetch address" do
    attachment = TicketEmailAttachments.for([ticket]).sole
    other = TicketEmailAttachments.for([wallet_ticket]).sole
    10.times { get attachment_path(attachment) }
    expect(response).to have_http_status(:ok)
    get attachment_path(attachment)
    expect(response).to have_http_status(:too_many_requests)
    get attachment_path(other)
    expect(response).to have_http_status(:ok)
  end

  it "answers HEAD without rendering and counts it against the link's limit" do
    attachment = TicketEmailAttachments.for([ticket]).sole
    allow(TicketPdfGenerator).to receive(:new).and_call_original
    10.times { head attachment_path(attachment) }
    expect(response).to have_http_status(:ok)
    expect(response.media_type).to eq("application/pdf")
    expect(TicketPdfGenerator).not_to have_received(:new)
    head attachment_path(attachment)
    expect(response).to have_http_status(:too_many_requests)
    get attachment_path(attachment)
    expect(response).to have_http_status(:too_many_requests)
  end

  it "gives no PDF to tickets for a cancelled or postponed event, matching admission" do
    cancelled = wallet_ticket
    cancelled.event.update_columns(status: Event.statuses[:cancelled])
    postponed = wallet_ticket
    postponed.event.update_columns(status: Event.statuses[:postponed])
    expect(TicketEmailAttachments.for([cancelled.reload, postponed.reload])).to eq([])
    expect([cancelled, postponed].map(&:admission_allowed?)).to eq([false, false])
  end

  it "words the email note from what was actually attached" do
    order = ticket.order
    blocked = create(:ticket, order: order, event: ticket.event, ticket_type: ticket.ticket_type, order_item: ticket.order_item)
    blocked.update!(status: :cancelled, cancelled_at: Time.current)
    html = EmailService.prepare_delivery_payload(create(:message_delivery, order: order, recipient: order.buyer_email)).fetch("html")
    expect(html).to include("1 of your 2 tickets are attached as PDFs")

    blocked.update_columns(status: Ticket.statuses[:issued])
    stub_const("TicketEmailAttachments::MAX_ATTACHMENTS", 1)
    html = EmailService.prepare_delivery_payload(create(:message_delivery, order: order.reload, recipient: order.buyer_email)).fetch("html")
    expect(html).to include("The first 1 tickets are attached as PDFs", "Open the rest from ", "View your order")
    expect(html).not_to include("/my-tickets")

    stub_const("TicketEmailAttachments::MAX_ATTACHMENTS", 10)
    html = EmailService.prepare_delivery_payload(create(:message_delivery, order: order.reload, recipient: order.buyer_email)).fetch("html")
    expect(html).to include("All 2 tickets are also attached as PDFs")
  end

  it "rejects forged tokens and skips attachments without a public HTTPS API" do
    get "/api/v1/ticket_email_attachments/forged--token"
    expect(response).to have_http_status(:not_found)

    stub_const("ENV", ENV.to_h.merge("PUBLIC_API_URL" => "http://localhost:3000"))
    expect(TicketEmailAttachments.for([ticket])).to eq([])
  end

  it "caps attachments per email" do
    stub_const("TicketEmailAttachments::MAX_ATTACHMENTS", 2)
    tickets = Array.new(3) { create(:ticket, order: ticket.order, event: ticket.event, ticket_type: ticket.ticket_type, order_item: ticket.order_item) }
    expect(TicketEmailAttachments.for(tickets).length).to eq(2)
  end

  it "freezes the attachment reference in the durable payload, so a retried send sends the same request" do
    delivery = create(:message_delivery, order: ticket.order, recipient: ticket.order.buyer_email)
    allow(EmailService).to receive(:configured?).and_return(true)
    captured = []
    allow(Resend::Emails).to receive(:send) do |params, options:|
      captured << [params.to_json, options.deep_dup]
      raise "provider response lost" if captured.length == 1

      { id: "synthetic-provider-email" }
    end

    expect { MessageDeliveryJob.new.perform(delivery.id) }.to raise_error("provider response lost")
    payload = delivery.reload.outbound_payload
    expect(payload.fetch("attachments")).to eq([{ "filename" => "hafapass-ticket-#{ticket.id}.pdf",
      "path" => payload.dig("attachments", 0, "path") }])
    expect(payload.to_json.bytesize).to be < 20_000
    travel_to(2.hours.from_now) { MessageDeliveryJob.new.perform(delivery.id) }

    expect(captured[0]).to eq(captured[1])
    expect(JSON.parse(captured[1][0]).fetch("attachments").length).to eq(1)
  end

  it "attaches the PDF to a single-ticket email but not for a transferred-away buyer copy" do
    payload = EmailService.prepare_delivery_payload(create(:message_delivery, template: "ticket_delivery", ticket: ticket,
      order: ticket.order, recipient: ticket.attendee_email))
    expect(payload.fetch("attachments").sole.fetch("filename")).to eq("hafapass-ticket-#{ticket.id}.pdf")
    expect(payload.fetch("html")).to include("attached as a PDF")

    ticket.update!(holder_user: create(:user), holder_email: "new-holder@example.com")
    order_payload = EmailService.prepare_delivery_payload(create(:message_delivery, order: ticket.order,
      recipient: ticket.order.buyer_email))
    expect(order_payload).not_to have_key("attachments")
    expect(order_payload.fetch("html")).not_to include("attached as PDFs")
  end
end
