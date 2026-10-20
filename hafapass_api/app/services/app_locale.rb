# frozen_string_literal: true

# The languages HåfaPass speaks, and how a request, an order or an email picks
# one. English is the source language: organizers write in it, policies are
# authoritative in it, and anything without a translation falls back to it.
#
# Codes match the frontend locale files. "tl" is Filipino (Tagalog); General
# Translation calls it "fil". CHamoru ("ch") is planned with human
# translators, so it is accepted for organizer-written content that already
# exists but is not offered to buyers or machine translated yet.
module AppLocale
  DEFAULT = "en"
  SUPPORTED = %w[en ko ja zh-Hant zh tl].freeze
  TRANSLATION_TARGETS = (SUPPORTED - [DEFAULT]).freeze
  ORGANIZER_CONTENT_LOCALES = (TRANSLATION_TARGETS + %w[ch]).freeze
  GT_CODES = { "tl" => "fil" }.freeze
  TRADITIONAL_CHINESE_REGIONS = %w[tw hk mo].freeze

  module_function

  # Maps a language tag ("ko-KR", "zh_TW", "fil") to a supported code, or nil.
  def normalize(value)
    parts = value.to_s.strip.tr("_", "-").downcase.split("-")
    case parts.first
    when "en", "ko", "ja" then parts.first
    when "tl", "fil" then "tl"
    when "zh" then chinese_variant(parts.drop(1))
    end
  end

  # An explicit ?locale= wins over the Accept-Language header; English otherwise.
  def resolve(param: nil, accept_language: nil)
    normalize(param) || from_accept_language(accept_language) || DEFAULT
  end

  def from_accept_language(header)
    ranges = header.to_s.split(",").first(20).each_with_index.filter_map do |part, index|
      tag, *options = part.strip.split(";")
      quality = options.map(&:strip).find { |option| option.start_with?("q=") }&.delete_prefix("q=")
      weight = quality ? Float(quality, exception: false).to_f : 1.0
      [tag.to_s.strip, weight, index] if tag.present? && weight.positive?
    end
    ranges.sort_by { |_, weight, index| [-weight, index] }.each do |tag, _, _|
      code = normalize(tag)
      return code if code
    end
    nil
  end

  # Stored locales are always supported codes; anything else reads as English.
  def i18n_locale(code)
    (SUPPORTED.include?(code.to_s) ? code.to_s : DEFAULT).to_sym
  end

  def gt_code(code)
    GT_CODES.fetch(code, code)
  end

  def chinese_variant(subtags)
    return "zh" if subtags.include?("hans")
    return "zh-Hant" if subtags.include?("hant") || subtags.intersect?(TRADITIONAL_CHINESE_REGIONS)

    "zh"
  end
end
