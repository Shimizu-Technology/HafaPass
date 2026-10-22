# frozen_string_literal: true

class OrganizerTaxInformation < ApplicationRecord
  CLASSIFICATIONS = %w[individual single_member_llc c_corp s_corp partnership trust_estate llc_c llc_s llc_p nonprofit government].freeze
  CERTIFICATION_VERSION = "w9-2026-10-v1"
  MATCH_RESULTS = {
    0 => "matched", 1 => "missing_or_invalid", 2 => "not_issued", 3 => "mismatch",
    4 => "invalid_request", 5 => "duplicate", 6 => "matched_ssn", 7 => "matched_ein", 8 => "matched_both"
  }.freeze
  CERTIFICATION = "Under penalties of perjury, I certify that the taxpayer identification number I provided is correct; " \
    "I am not subject to backup withholding because I am exempt, the IRS has not told me I am subject to it, " \
    "or the IRS has told me it no longer applies; I am a U.S. citizen or other U.S. person; " \
    "FATCA exemption certification does not apply because this form does not collect a FATCA exemption code. " \
    "I am authorized to sign for this payee."

  belongs_to :organization
  has_many :tin_match_requests, dependent: :restrict_with_exception
  encrypts :tin
  self.filter_attributes += [:tin]

  validates :legal_name, :mailing_address, :signer_name, :certified_at, :certification_version, presence: true
  validates :legal_name, :business_name, :signer_name, length: { maximum: 200 }
  validates :mailing_address, length: { maximum: 1000 }
  validates :exempt_payee_code, format: { with: /\A(?:[1-9]|1[0-3])?\z/ }, allow_nil: true
  validates :tax_classification, inclusion: { in: CLASSIFICATIONS }
  validates :tin_type, inclusion: { in: %w[ssn ein] }
  validates :tin, format: { with: /\A[0-9]{9}\z/, message: "must contain exactly 9 digits" }
  validates :organization_id, uniqueness: true
  validates :tin_match_status, inclusion: { in: ["unverified", *MATCH_RESULTS.values] }
  validates :backup_withholding_reason, presence: true, if: :backup_withholding_flag?
  before_validation :set_last_four

  def masked_tin
    "***-**-#{tin_last_four}"
  end

  def backup_withholding_required?
    backup_withholding_flag? || (tin_match_status == "mismatch" && b_notice_response_due_on.present? &&
      Date.current > b_notice_response_due_on)
  end

  # Explicit allowlist: ciphertext and plaintext never enter normal responses.
  def safe_json
    %w[legal_name business_name tax_classification tin_type mailing_address exempt_payee_code
       signer_name certified_at certification_version].index_with { |field| public_send(field) }.merge(
        "masked_tin" => masked_tin, "w9_on_file" => certified_at.present?,
        "tin_match_status" => tin_match_status, "tin_match_result_code" => tin_match_result_code,
        "b_notice_stage" => b_notice_stage, "b_notice_sent_at" => b_notice_sent_at,
        "b_notice_response_due_on" => b_notice_response_due_on,
        "backup_withholding_flag" => backup_withholding_flag,
        "backup_withholding_required" => backup_withholding_required?)
  end

  def serializable_hash(*)
    safe_json
  end

  private

  def set_last_four
    self.tin_last_four = tin.to_s.last(4)
  end
end
