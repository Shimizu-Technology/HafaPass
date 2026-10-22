# frozen_string_literal: true

# IRS e-Services bulk matching is performed by an enrolled operator. Only the
# generated download and the operator's upload contain complete TINs.
class TinMatching
  class ImportError < StandardError; end

  def self.match_name(tax)
    ActiveSupport::Inflector.transliterate(tax.legal_name.to_s).gsub(/[^A-Za-z0-9&\- ]/, "").squish.first(40)
  end

  def self.export!(actor:, request: nil)
    rows = []
    TinMatchRequest.transaction do
      OrganizerTaxInformation.where(tin_match_status: "unverified").order(:id).find_each do |tax|
        reference = SecureRandom.hex(10)
        TinMatchRequest.create!(organizer_tax_information: tax, account_reference: reference,
          tax_information_updated_at: tax.updated_at, exported_at: Time.current)
        name = match_name(tax)
        raise ImportError, "A payee has no IRS-compatible matching name" if name.blank?
        rows << [tax.tin_type == "ein" ? "1" : "2", tax.tin, name, reference].join(";")
      end
      AuditLogger.record!(action: "tin_matching.exported", auditable: actor, actor: actor,
        metadata: { count: rows.length }, request: request)
    end
    rows.join("\n") + (rows.any? ? "\n" : "")
  end

  def self.import!(content:, actor:, request: nil)
    raise ImportError, "Result file is too large" if content.bytesize > 12_000_000

    lines = content.encode("UTF-8", invalid: :replace, undef: :replace).lines.map(&:strip).reject(&:blank?)
    raise ImportError, "Result file is empty" if lines.empty?
    raise ImportError, "Result file exceeds 100,000 rows" if lines.length > 100_000

    counts = Hash.new(0)
    TinMatchRequest.transaction do
      seen = Set.new
      lines.each do |line|
        type, tin, name, reference, code_text = line.split(";", -1).map(&:strip)
        unless line.count(";") == 4 && code_text&.match?(/\A[0-8]\z/) && reference&.match?(/\A[0-9a-f]{20}\z/)
          raise ImportError, "Result file has an invalid row"
        end
        raise ImportError, "Result file contains a repeated account reference" unless seen.add?(reference)

        match = TinMatchRequest.includes(:organizer_tax_information).find_by(account_reference: reference)
        raise ImportError, "Unknown or already imported account reference" unless match && !match.imported_at

        tax = match.organizer_tax_information
        tax.organization.lock!
        tax.lock!
        expected_name = match_name(tax)
        unless tax.updated_at == match.tax_information_updated_at &&
            type == (tax.tin_type == "ein" ? "1" : "2") && tin == tax.tin && name == expected_name
          raise ImportError, "Result file does not match the current W-9; export a new request"
        end
        code = code_text.to_i
        status = OrganizerTaxInformation::MATCH_RESULTS.fetch(code)
        tax.update!(tin_match_status: status, tin_match_result_code: code, tin_matched_at: Time.current,
          **(status == "mismatch" ? { irs_validation_evidence_type: nil, irs_validation_recorded_on: nil,
            irs_validation_admin_id: nil, irs_validation_document_reference: nil } : {}))
        match.update!(result_code: code, imported_at: Time.current)
        counts[tax.tin_match_status] += 1
      end
      AuditLogger.record!(action: "tin_matching.imported", auditable: actor, actor: actor,
        metadata: { count: lines.length, statuses: counts }, request: request)
    end
    counts
  end
end
