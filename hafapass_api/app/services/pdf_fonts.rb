# frozen_string_literal: true

# Bundled fonts for generated PDFs (tickets and door lists). Noto Sans covers
# Latin and CHamoru text; Japanese, Korean, Traditional and Simplified Chinese
# and emoji come from fallback fonts that are only loaded when the text needs
# them. Han characters are shared by several of those fonts, so the font for
# the text's language goes first to get the regional glyph shapes right. See
# app/assets/fonts/tickets/README.md for sources and licences.
module PdfFonts
  class UnsupportedCharacterError < StandardError; end

  DIRECTORY = Rails.root.join("app/assets/fonts/tickets").freeze
  BASE = "TicketSans"
  FALLBACK_FILES = {
    "TicketJapanese" => "NotoSansJP-Regular.ttf",
    "TicketKorean" => "NotoSansKR-Regular.ttf",
    "TicketChineseTraditional" => "NotoSansTC-Regular.ttf",
    "TicketChineseSimplified" => "NotoSansSC-Regular.ttf",
    "TicketEmoji" => "NotoEmoji-Regular.ttf"
  }.freeze
  CJK_ORDER = %w[TicketJapanese TicketKorean TicketChineseTraditional TicketChineseSimplified].freeze
  LOCALE_FONTS = {
    "ja" => "TicketJapanese", "ko" => "TicketKorean",
    "zh-Hant" => "TicketChineseTraditional", "zh" => "TicketChineseSimplified"
  }.freeze

  module_function

  # Registers the fonts, chooses fallbacks that cover every character in
  # `texts`, and sets the document font. When no bundled font can draw a
  # character it raises UnsupportedCharacterError (naming only code points),
  # or with strict: false returns those characters for the caller to replace.
  def configure(pdf, texts:, locale: nil, strict: true)
    pdf.font_families.update(BASE => {
      normal: DIRECTORY.join("NotoSans-Regular.ttf").to_s, bold: DIRECTORY.join("NotoSans-Bold.ttf").to_s
    })
    FALLBACK_FILES.each do |family, file|
      path = DIRECTORY.join(file).to_s
      pdf.font_families.update(family => { normal: path, bold: path })
    end

    remaining = uncovered(pdf, BASE, Array(texts).compact.join.each_char.uniq.reject { |character| character.match?(/\s/) })
    fallbacks = preferred_fallbacks(Array(texts).compact.join, locale).select do |family|
      next false if remaining.empty?

      before = remaining.length
      remaining = uncovered(pdf, family, remaining)
      remaining.length < before
    end
    if strict && remaining.any?
      codepoints = remaining.map { |character| "U+#{character.ord.to_s(16).upcase}" }.join(", ")
      raise UnsupportedCharacterError, "Ticket PDF fonts do not support #{codepoints}"
    end

    pdf.fallback_fonts = fallbacks
    pdf.font BASE
    remaining
  end

  def preferred_fallbacks(text, locale)
    leading = []
    leading << "TicketKorean" if text.match?(/\p{Hangul}/)
    leading << "TicketJapanese" if text.match?(/[\p{Hiragana}\p{Katakana}]/)
    leading << LOCALE_FONTS[AppLocale.normalize(locale)] if LOCALE_FONTS[AppLocale.normalize(locale)]
    (leading + CJK_ORDER).uniq + ["TicketEmoji"]
  end

  def uncovered(pdf, family, characters)
    return characters if characters.empty?

    missing = characters
    pdf.font(family) do
      font = pdf.font
      missing = characters.reject { |character| font.glyph_present?(character) }
    end
    missing
  end
end
