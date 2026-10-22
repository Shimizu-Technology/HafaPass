# frozen_string_literal: true

class AnnualTaxThreshold < ApplicationRecord
  DEFAULT_AMOUNTS = { "1099-nec" => 200_000, "1099-misc" => 200_000, "1099-k" => 2_000_000 }.freeze

  def self.for(year:, form_type:)
    return nil unless DEFAULT_AMOUNTS.key?(form_type)

    find_by(year: year, form_type: form_type) || new(year: year, form_type: form_type,
      amount_cents: year.to_i < 2026 && form_type != "1099-k" ? 60_000 : DEFAULT_AMOUNTS.fetch(form_type),
      transaction_count: form_type == "1099-k" ? 200 : nil)
  end

  validates :year, numericality: { only_integer: true, in: 2000..2100 }, uniqueness: { scope: :form_type }
  validates :form_type, inclusion: { in: %w[1099-nec 1099-misc 1099-k] }
  validates :amount_cents, numericality: { only_integer: true, greater_than_or_equal_to: 0 }
  validates :transaction_count, numericality: { only_integer: true, greater_than: 0 }, allow_nil: true
end
