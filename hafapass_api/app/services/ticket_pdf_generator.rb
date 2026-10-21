require "prawn"
require "rqrcode"

class TicketPdfGenerator
  UnsupportedCharacterError = PdfFonts::UnsupportedCharacterError

  BRAND_TEAL = "0D9488"
  BRAND_CORAL = "F97316"
  DARK_TEXT = "1A1A1A"
  MUTED_TEXT = "6B7280"
  LIGHT_BG = "F9FAFB"
  FONT_DIRECTORY = PdfFonts::DIRECTORY
  QR_BLOCK_HEIGHT = 220

  def initialize(ticket)
    @ticket = ticket
    @event = ticket.event
    @ticket_type = ticket.ticket_type
    @scan_credential = ticket.scan_credential
    @seller = SellerIdentity.for_event(@event)
  end

  def generate
    Prawn::Document.new(page_size: "A5", margin: [110, 30, 30, 30]) do |pdf|
      # Picks fonts for every character before the QR is made; text no bundled
      # font can draw raises instead of printing missing-glyph boxes.
      @unsupported = PdfFonts.configure(pdf, texts: [@event.title, @event.venue_name, @event.venue_address, @ticket_type.name,
        @ticket.seat_label, @seller.line], locale: @ticket.order&.locale, strict: false)
      # Reserve the header in the page margin so flowing text cannot overlap
      # repeated branding or rehearsal labels on continuation pages.
      pdf.repeat(:all, dynamic: true) do
        pdf.bounding_box([0, pdf.bounds.top + 80], width: pdf.bounds.width, height: 80) do
          render_header(pdf)
        end
      end
      render_event_details(pdf)
      render_divider(pdf)
      render_ticket_details(pdf)
      render_qr_code(pdf)
      render_footer(pdf)
    end.render
  end

  private

  def render_header(pdf)
    # Brand bar
    pdf.fill_color BRAND_TEAL
    pdf.fill_rectangle [0, pdf.cursor], pdf.bounds.width, 4
    pdf.move_down 12

    # Title
    pdf.fill_color DARK_TEXT
    pdf.font "TicketSans", style: :bold, size: 20
    pdf.text "HåfaPass", color: BRAND_TEAL
    pdf.move_down 4

    pdf.fill_color MUTED_TEXT
    pdf.font "TicketSans", size: 8
    pdf.text Rails.env.production? ? "EVENT TICKET" : "TEST TICKET - REHEARSAL ONLY"
    pdf.move_down 16
  end

  def render_event_details(pdf)
    pdf.fill_color DARK_TEXT
    pdf.font "TicketSans", style: :bold, size: 16
    pdf.text safe_text(@event.title)
    pdf.move_down 8

    if @event.cancelled? || @event.postponed?
      pdf.fill_color BRAND_CORAL
      pdf.font "TicketSans", style: :bold, size: 10
      pdf.text "EVENT #{@event.status.upcase} — check your email for updates"
      pdf.move_down 8
    end

    pdf.fill_color MUTED_TEXT
    pdf.font "TicketSans", size: 10

    starts = event_time(@event.starts_at)
    if starts
      pdf.text format_date(starts)
      time_str = format_time(starts)
      time_str += " – #{format_time(event_time(@event.ends_at))}" if @event.ends_at
      pdf.text time_str
    end

    pdf.text safe_text(@event.venue_name) if @event.venue_name.present?
    pdf.text safe_text(@event.venue_address) if @event.venue_address.present?
    pdf.move_down 12
  end

  def render_divider(pdf)
    pdf.stroke_color "D1D5DB"
    pdf.dash(3, space: 3)
    pdf.stroke_horizontal_line 0, pdf.bounds.width
    pdf.undash
    pdf.move_down 12
  end

  def render_ticket_details(pdf)
    pdf.fill_color DARK_TEXT
    pdf.font "TicketSans", style: :bold, size: 11
    pdf.text safe_text(@ticket_type.name)
    pdf.text safe_text(@ticket.seat_label) if @ticket.seat_label.present?

    pdf.move_down 4
    pdf.fill_color MUTED_TEXT
    pdf.font "TicketSans", size: 9
    pdf.text "TICKET #"
    pdf.fill_color DARK_TEXT
    pdf.font "Courier", size: 8
    pdf.text "HP-T#{@ticket.id}"
    pdf.move_down 16
  end

  def render_qr_code(pdf)
    # Positioned images do not flow onto the next page with text. Keep the
    # admission code, its identifier, and instructions inside one page.
    if pdf.cursor < QR_BLOCK_HEIGHT
      pdf.start_new_page
    end

    qr = RQRCode::QRCode.new(@scan_credential, level: :m)
    png = qr.as_png(size: 600, border_modules: 2)

    # Write to tempfile and embed
    tempfile = Tempfile.new(["qr", ".png"])
    tempfile.binmode
    tempfile.write(png.to_s)
    tempfile.rewind

    qr_size = 160
    x_offset = (pdf.bounds.width - qr_size) / 2
    pdf.image tempfile.path, at: [x_offset, pdf.cursor], width: qr_size
    pdf.move_down qr_size + 8

    # Barcode text
    pdf.fill_color MUTED_TEXT
    pdf.font "Courier", size: 7
    pdf.text "HP-T#{@ticket.id}", align: :center
    pdf.move_down 12
  ensure
    tempfile&.close
    tempfile&.unlink
  end

  def render_footer(pdf)
    pdf.fill_color MUTED_TEXT
    pdf.font "TicketSans", size: 9
    pdf.text Rails.env.production? ? "Present this QR code at the door" : "For testing only - no real event admission", align: :center
    pdf.move_down 4
    pdf.font "TicketSans", size: 7
    pdf.text safe_text(@seller.line), align: :center, color: "6B7280"
  end

  def safe_text(text)
    PdfFonts.replace_unsupported(text, @unsupported)
  end

  def format_date(datetime)
    datetime.strftime("%A, %B %-d, %Y")
  end

  def event_time(datetime)
    datetime&.in_time_zone(@event.timezone.presence || "Pacific/Guam")
  end

  def format_time(datetime)
    datetime.strftime("%-I:%M %p")
  end
end
