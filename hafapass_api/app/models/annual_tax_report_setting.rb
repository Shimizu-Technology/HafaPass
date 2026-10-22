# frozen_string_literal: true

class AnnualTaxReportSetting < ApplicationRecord
  FORM_TYPES = %w[review_required 1099-nec 1099-misc 1099-k none].freeze
  JURISDICTIONS = %w[irs guam_drt].freeze
  belongs_to :organization
  validates :year, numericality: { only_integer: true, in: 2000..2100 }, uniqueness: { scope: [:organization_id, :payee_key] }
  validates :payee_key, format: { with: /\A(?:all|[0-9a-f]{64})\z/ }
  validates :form_type, inclusion: { in: FORM_TYPES }
  validates :jurisdiction, inclusion: { in: JURISDICTIONS }
end
