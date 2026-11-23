# frozen_string_literal: true

module UsdMoney
  module_function

  def format_cents(cents, locale: I18n.locale)
    unit = %w[ko zh zh-Hant pt].include?(locale.to_s) ? "US$" : "$"
    ActiveSupport::NumberHelper.number_to_currency(cents / 100.0, unit: unit, precision: 2,
      delimiter: locale.to_s == "pt" ? "." : ",", separator: locale.to_s == "pt" ? "," : ".")
  end
end
