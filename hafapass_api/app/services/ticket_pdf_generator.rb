require "prawn"
require "rqrcode"

class TicketPdfGenerator
  BRAND_TEAL = "0D9488"
  BRAND_CORAL = "F97316"
  DARK_TEXT = "1A1A1A"
  MUTED_TEXT = "6B7280"
  LIGHT_BG = "F9FAFB"

  def initialize(ticket)
    @ticket = ticket
    @event = ticket.event
    @ticket_type = ticket.ticket_type
    @scan_credential = ticket.scan_credential
  end

  def generate
    Prawn::Document.new(page_size: "A5", margin: 30) do |pdf|
      render_header(pdf)
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
    pdf.font "Helvetica", style: :bold, size: 20
    pdf.text "HafaPass", color: BRAND_TEAL
    pdf.move_down 4

    pdf.fill_color MUTED_TEXT
    pdf.font "Helvetica", size: 8
    pdf.text "EVENT TICKET"
    pdf.move_down 16
  end

  def render_event_details(pdf)
    pdf.fill_color DARK_TEXT
    pdf.font "Helvetica", style: :bold, size: 16
    pdf.text @event.title
    pdf.move_down 8

    if @event.cancelled? || @event.postponed?
      pdf.fill_color BRAND_CORAL
      pdf.font "Helvetica", style: :bold, size: 10
      pdf.text "EVENT #{@event.status.upcase} — check your email for updates"
      pdf.move_down 8
    end

    pdf.fill_color MUTED_TEXT
    pdf.font "Helvetica", size: 10

    starts = event_time(@event.starts_at)
    if starts
      pdf.text format_date(starts)
      time_str = format_time(starts)
      time_str += " – #{format_time(event_time(@event.ends_at))}" if @event.ends_at
      pdf.text time_str
    end

    pdf.text @event.venue_name if @event.venue_name.present?
    pdf.text @event.venue_address if @event.venue_address.present?
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
    pdf.font "Helvetica", style: :bold, size: 11
    pdf.text @ticket_type.name

    pdf.move_down 4
    pdf.fill_color MUTED_TEXT
    pdf.font "Helvetica", size: 9
    pdf.text "TICKET #"
    pdf.fill_color DARK_TEXT
    pdf.font "Courier", size: 8
    pdf.text "HP-T#{@ticket.id}"
    pdf.move_down 16
  end

  def render_qr_code(pdf)
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
    pdf.font "Helvetica", size: 9
    pdf.text "Present this QR code at the door", align: :center
    pdf.move_down 4
    pdf.font "Helvetica", size: 7
    pdf.text "Powered by HafaPass", align: :center, color: "9CA3AF"
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
