require "rails_helper"
require "pdf/reader"

RSpec.describe TicketPdfGenerator do
  let(:event) do
    create(:event, :published, venue: create(:venue, name: "Hågatña 日本会館", address: "123 Nåna Street 東京"), title: "Music & Food <show> 🎟️ — 日本語とÅmot",
      venue_name: "Hågatña 日本会館", venue_address: "123 Nåna Street 東京",
      starts_at: Time.utc(2026, 10, 12, 8), ends_at: Time.utc(2026, 10, 12, 10))
  end
  let(:ticket_type) { create(:ticket_type, event: event, name: "大人 Åmot 🎟️") }
  let(:order) { create(:order, event: event) }
  let(:ticket) do
    create(:ticket, event: event, order: order, ticket_type: ticket_type,
      attendee_name: "PRIVATE 日本語 attendee", attendee_email: "private@synthetic.invalid")
  end

  def read_pdf
    PDF::Reader.new(StringIO.new(described_class.new(ticket).generate))
  end

  it "embeds fonts that preserve multilingual event, venue, type and seat text" do
    configuration = create(:event_seating_configuration, event: event)
    seat = create(:event_seat, event_seating_configuration: configuration, ticket_type: ticket_type)
    seat.venue_seat.seating_row.seating_section.update!(name: "日本 Åmot")
    seat.venue_seat.seating_row.update!(label: "列あ")
    seat.venue_seat.update!(label: "席一")
    ticket.update!(event_seat: seat)

    allow_any_instance_of(Prawn::Document).to receive(:text).and_call_original
    expect_any_instance_of(Prawn::Document).to receive(:text).with(event.title).and_call_original
    text = read_pdf.pages.map(&:text).join("\n")
    [event.title, event.venue_name, event.venue_address, ticket_type.name, ticket.seat_label].each do |value|
      # PDF::Reader omits the invisible emoji variation selector; the original
      # string is still passed intact to Prawn and the emoji font supports it.
      expect(text).to include(value.delete("\uFE0F"))
    end
    expect(text).to include("6:00 PM", "8:00 PM", "TEST TICKET - REHEARSAL ONLY", "HP-T#{ticket.id}")
    expect(text).not_to include(ticket.attendee_name, ticket.attendee_email, ticket.scan_credential, ticket.display_credential)
  end

  it "replaces unsupported glyphs and still creates the admission QR" do
    event.update!(title: "Unsupported \u{10FFFF}")
    expect(RQRCode::QRCode).to receive(:new).and_call_original
    expect(read_pdf.pages.map(&:text).join("\n")).to include("Unsupported ?")
  end

  {
    "Korean" => ["서울 재즈 페스티벌 괌", "일반 입장", "ko", "TicketKorean"],
    "Japanese" => ["グアム花火大会", "大人", "ja", "TicketJapanese"],
    "Traditional Chinese" => ["關島夏日音樂會", "一般入場", "zh-Hant", "TicketChineseTraditional"],
    "Simplified Chinese" => ["关岛夏日音乐会", "普通门票", "zh", "TicketChineseSimplified"]
  }.each do |language, (title, type_name, locale, font)|
    it "renders a #{language} event title with the #{language} font first" do
      event.update!(title: title, venue_name: "Tumon Bay", venue_address: "Tumon")
      ticket_type.update!(name: type_name)
      order.update!(locale: locale)
      fallbacks = nil
      allow(PdfFonts).to receive(:configure).and_wrap_original do |original, pdf, **options|
        original.call(pdf, **options).tap { fallbacks = pdf.fallback_fonts }
      end

      text = read_pdf.pages.map(&:text).join("\n")

      expect(text).to include(title, type_name)
      expect(fallbacks.first).to eq(font)
    end
  end

  it "loads no CJK font for Latin-only tickets" do
    event.update!(title: "Hafa Adai Night", venue_name: "Hagåtña", venue_address: "Hagåtña")
    ticket_type.update!(name: "General")
    pdf = Prawn::Document.new

    expect(PdfFonts.configure(pdf, texts: [event.title, ticket_type.name])).to be_empty
    expect(pdf.fallback_fonts).to be_empty
  end

  it "uses the current admission credential for the QR, never the public display link" do
    expect(RQRCode::QRCode).to receive(:new).with(ticket.scan_credential, level: :m).and_call_original
    expect(read_pdf.pages).not_to be_empty
  end

  it "retains a postponed event notice" do
    event.update!(status: :postponed)
    expect(read_pdf.pages.map(&:text).join("\n")).to include("EVENT POSTPONED — check your email for updates")
  end

  it "keeps the full long text and the QR instructions on a continuation page" do
    event.update!(title: "日本語Åmot🎟️ " * 35, venue_address: "Hågatña 東京 " * 80)
    reader = read_pdf
    text = reader.pages.map { |page| page.text(skip_overlapping: false) }.join("\n").gsub("HåfaPass", "").gsub("TEST TICKET - REHEARSAL ONLY", "").gsub(/\s+/, "")
    expect(reader.page_count).to be > 1
    expect(text).to include(event.title.delete("\uFE0F").gsub(/\s+/, ""))
    expect(text.scan("Hågatña").size).to eq(81)
    expect(text.scan("東京").size).to eq(80)
    last = reader.pages.last
    expect(last.text).to include("HåfaPass", "TEST TICKET - REHEARSAL ONLY", "HP-T#{ticket.id}",
      "For testing only - no real event admission", "Sold by #{event.organizer_profile.business_name} · Tickets by HåfaPass")
    expect(last.xobjects.values.any? { |object| object.hash[:Subtype] == :Image }).to be(true)
  end
end
