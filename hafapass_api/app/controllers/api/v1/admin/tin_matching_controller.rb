# frozen_string_literal: true

class Api::V1::Admin::TinMatchingController < Api::V1::Admin::BaseController
  before_action -> { response.headers["Cache-Control"] = "no-store" }

  def index
    records = OrganizerTaxInformation.includes(:organization).order(:id)
    render json: { payees: records.map { |tax| { organization_id: tax.organization_id,
      organization_name: tax.organization.name, tax_information: tax.safe_json,
      under_withheld_cents: PayeeWithholdingBalance.for_tax(tax) } } }
  end

  def export
    unless params[:confirm_full_tins] == true || params[:confirm_full_tins] == "true"
      return render json: { error: "Explicitly confirm full-TIN export" }, status: :unprocessable_entity
    end
    purpose = params[:purpose].to_s.strip
    unless BackupWithholding.safe_reason?(purpose)
      error = BackupWithholding.safe_text?(purpose) ?
        "Full-TIN export requires a 10-1000 character purpose" : BackupWithholding::TIN_WARNING
      return render json: { error: error }, status: :unprocessable_entity
    end
    data = TinMatching.export!(actor: current_user, purpose: purpose, request: request)
    send_data data, filename: "tin-matching-#{Date.current}-SENSITIVE-FULL-TINS.txt", type: "text/plain", disposition: "attachment"
  rescue TinMatching::ImportError => e
    render json: { error: e.message }, status: :unprocessable_entity
  end

  def import
    upload = params[:file]
    unless upload.respond_to?(:read)
      AuditLogger.record!(action: "tin_matching.import_failed", auditable: current_user, actor: current_user,
        metadata: { reason: "missing_file" }, request: request)
      return render json: { error: "Select an IRS result text file" }, status: :unprocessable_entity
    end

    size = upload.respond_to?(:size) ? upload.size : upload.tempfile.size
    raise TinMatching::ImportError, "Result file is too large" if size > 12_000_000
    content = upload.read(12_000_001)
    raise TinMatching::ImportError, "Result file is too large" if content.bytesize > 12_000_000
    result = TinMatching.import!(content: content, actor: current_user, request: request)
    render json: { imported: result.values.sum, statuses: result }
  rescue TinMatching::ImportError => e
    AuditLogger.record!(action: "tin_matching.import_failed", auditable: current_user, actor: current_user,
      metadata: { reason: e.message }, request: request)
    render json: { error: e.message }, status: :unprocessable_entity
  end

  def flag
    tax = Organization.find(params[:organization_id]).organizer_tax_information
    return render json: { error: "No W-9 on file" }, status: :not_found unless tax

    flagged = ActiveModel::Type::Boolean.new.cast(params[:flagged])
    reason = params[:reason].to_s.strip
    unless BackupWithholding.safe_reason?(reason)
      error = BackupWithholding.safe_text?(reason) ? "Give a 10-1000 character reason" : BackupWithholding::TIN_WARNING
      return render json: { error: error }, status: :unprocessable_entity
    end

    tax.organization.with_lock do
      tax.lock!
      tax.update!(backup_withholding_flag: flagged, backup_withholding_reason: flagged ? reason : nil)
      AuditLogger.record!(action: "tax_information.withholding_flag_changed", auditable: tax, actor: current_user,
        metadata: { flagged: flagged, reason: reason }, request: request)
    end
    render json: { tax_information: tax.safe_json }
  end

  def notice_pdf
    tax = Organization.find(params[:organization_id]).organizer_tax_information
    return render json: { error: "No W-9 on file" }, status: :not_found unless tax

    stage = params[:stage].to_s
    data = BNotice.pdf(tax: tax, stage: stage)
    AuditLogger.record!(action: "tax_information.b_notice_generated", auditable: tax, actor: current_user,
      metadata: { stage: stage }, request: request)
    send_data data, filename: "b-notice-#{stage}-#{tax.organization_id}.pdf", type: "application/pdf", disposition: "attachment"
  rescue BNotice::NoticeError => e
    render json: { error: e.message }, status: :unprocessable_entity
  end

  def validate_second_notice
    tax = Organization.find(params[:organization_id]).organizer_tax_information
    return render json: { error: "No W-9 on file" }, status: :not_found unless tax
    evidence = params[:evidence_type].to_s
    required = tax.tin_type == "ssn" ? "ssa_card" : "irs_letter_147c"
    reference = params[:document_reference].to_s.strip
    recorded_on = Date.iso8601(params[:recorded_on].to_s)
    unless tax.b_notice_stage == "second" && !tax.irs_validation_current? &&
        evidence == required && recorded_on <= Date.current &&
        reference.length <= 255 && BackupWithholding.safe_text?(reference)
      error = BackupWithholding.safe_text?(reference) ?
        "Record the required IRS or SSA evidence, a valid date, and a reference" : BackupWithholding::TIN_WARNING
      return render json: { error: error }, status: :unprocessable_entity
    end
    tax.organization.with_lock do
      tax.lock!
      raise BNotice::NoticeError, "Second notice validation state changed; reload and retry" unless
        tax.b_notice_stage == "second" && !tax.irs_validation_current? &&
        evidence == (tax.tin_type == "ssn" ? "ssa_card" : "irs_letter_147c")
      tax.update!(irs_validation_evidence_type: evidence, irs_validation_recorded_on: recorded_on,
        irs_validation_admin: current_user, irs_validation_document_reference: reference.presence,
        validation_identity_digest: tax.current_identity_digest, tin_match_status: "matched")
      AuditLogger.record!(action: "tax_information.second_b_notice_validated", auditable: tax,
        actor: current_user, metadata: { evidence_type: evidence, recorded_on: recorded_on,
          document_reference: reference.presence }, request: request)
    end
    render json: { tax_information: tax.safe_json }
  rescue Date::Error
    render json: { error: "Use an ISO date" }, status: :unprocessable_entity
  rescue BNotice::NoticeError => e
    render json: { error: e.message }, status: :unprocessable_entity
  end

  def notice_received
    tax = Organization.find(params[:organization_id]).organizer_tax_information
    return render json: { error: "No W-9 on file" }, status: :not_found unless tax
    return render json: { error: "TIN mismatch is required" }, status: :unprocessable_entity unless tax.tin_match_status == "mismatch"

    received_on = Date.iso8601(params[:received_on].to_s)
    return render json: { error: "Receipt date cannot be in the future" }, status: :unprocessable_entity if received_on > Date.current
    stage = nil
    tax.organization.with_lock do
      tax.lock!
      raise BNotice::NoticeError, "TIN mismatch is required" unless tax.tin_match_status == "mismatch"
      first_receipt = tax.first_b_notice_received_on || (tax.b_notice_stage == "first" && tax.b_notice_sent_at&.to_date)
      stage = first_receipt && received_on > first_receipt &&
        received_on < first_receipt + 3.years ? "second" : "first"
      tax.update!(irs_notice_received_on: received_on,
        irs_validation_evidence_type: nil, irs_validation_recorded_on: nil,
        irs_validation_admin_id: nil, irs_validation_document_reference: nil, validation_identity_digest: nil,
        b_notice_send_due_on: BNotice.business_days_after(received_on, 15),
        b_notice_response_due_on: BNotice.business_days_after(received_on, 30))
      AuditLogger.record!(action: "tax_information.irs_notice_received", auditable: tax,
        actor: current_user, metadata: { received_on: received_on, stage: stage,
          send_due_on: tax.b_notice_send_due_on, withholding_due_on: tax.b_notice_response_due_on }, request: request)
    end
    render json: { tax_information: tax.safe_json, next_stage: stage }
  rescue Date::Error
    render json: { error: "Use an ISO date" }, status: :unprocessable_entity
  rescue BNotice::NoticeError => e
    render json: { error: e.message }, status: :unprocessable_entity
  end

  def notice_sent
    tax = Organization.find(params[:organization_id]).organizer_tax_information
    return render json: { error: "No W-9 on file" }, status: :not_found unless tax

    stage = params[:stage].to_s
    return render json: { error: "Choose first or second notice" }, status: :unprocessable_entity unless %w[first second].include?(stage)
    return render json: { error: "TIN mismatch is required before a B-notice" }, status: :unprocessable_entity unless tax.tin_match_status == "mismatch"
    first_receipt = tax.first_b_notice_received_on || (tax.b_notice_stage == "first" && tax.b_notice_sent_at&.to_date)
    expected_stage = first_receipt && tax.irs_notice_received_on &&
      tax.irs_notice_received_on > first_receipt &&
      tax.irs_notice_received_on < first_receipt + 3.years ? "second" : "first"
    return render json: { error: "Notice stage does not match IRS notice history" }, status: :unprocessable_entity unless stage == expected_stage
    received_on = tax.irs_notice_received_on
    return render json: { error: "Record IRS notice receipt first" }, status: :unprocessable_entity unless received_on
    return render json: { error: "This notice was already recorded" }, status: :unprocessable_entity if tax.b_notice_sent_at.present? && tax.b_notice_stage == stage && tax.b_notice_sent_at.to_date >= received_on
    sent_on = Date.iso8601(params[:sent_on].to_s)
    return render json: { error: "Sent date cannot be in the future" }, status: :unprocessable_entity if sent_on > Date.current

    send_due = BNotice.business_days_after(received_on, 15)
    if sent_on < received_on
      return render json: { error: "Sent date must follow IRS notice receipt" }, status: :unprocessable_entity
    end
    tax.organization.with_lock do
      tax.lock!
      raise BNotice::NoticeError, "Notice state changed; reload and retry" unless
        tax.tin_match_status == "mismatch" && tax.irs_notice_received_on == received_on &&
        tax.next_b_notice_stage == stage
      tax.update!(b_notice_stage: stage, b_notice_sent_at: sent_on.in_time_zone,
        irs_notice_received_on: received_on, b_notice_send_due_on: send_due,
        b_notice_identity_digest: (tax.current_identity_digest if stage == "second"),
        first_b_notice_received_on: stage == "first" ? received_on : tax.first_b_notice_received_on,
        b_notice_response_due_on: BNotice.business_days_after(received_on, 30),
        irs_validation_evidence_type: nil, irs_validation_recorded_on: nil,
        irs_validation_admin_id: nil, irs_validation_document_reference: nil, validation_identity_digest: nil)
      AuditLogger.record!(action: "tax_information.b_notice_sent", auditable: tax, actor: current_user,
        metadata: { stage: stage, received_on: received_on, send_due_on: send_due, sent_on: sent_on,
          response_due_on: tax.b_notice_response_due_on }, request: request)
    end
    render json: { tax_information: tax.safe_json }
  rescue Date::Error
    render json: { error: "Use an ISO date" }, status: :unprocessable_entity
  rescue BNotice::NoticeError => e
    render json: { error: e.message }, status: :unprocessable_entity
  end
end
