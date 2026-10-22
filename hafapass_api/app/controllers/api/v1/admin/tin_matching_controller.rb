# frozen_string_literal: true

class Api::V1::Admin::TinMatchingController < Api::V1::Admin::BaseController
  before_action -> { response.headers["Cache-Control"] = "no-store" }

  def index
    records = OrganizerTaxInformation.includes(:organization).order(:id)
    render json: { payees: records.map { |tax| { organization_id: tax.organization_id,
      organization_name: tax.organization.name, tax_information: tax.safe_json } } }
  end

  def export
    data = TinMatching.export!(actor: current_user, request: request)
    send_data data, filename: "tin-matching-#{Date.current}.txt", type: "text/plain", disposition: "attachment"
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

    result = TinMatching.import!(content: upload.read, actor: current_user, request: request)
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
      return render json: { error: "Give a 10-1000 character reason without a TIN" }, status: :unprocessable_entity
    end

    tax.update!(backup_withholding_flag: flagged, backup_withholding_reason: flagged ? reason : nil)
    AuditLogger.record!(action: "tax_information.withholding_flag_changed", auditable: tax, actor: current_user,
      metadata: { flagged: flagged, reason: reason }, request: request)
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

  def notice_sent
    tax = Organization.find(params[:organization_id]).organizer_tax_information
    return render json: { error: "No W-9 on file" }, status: :not_found unless tax

    stage = params[:stage].to_s
    return render json: { error: "Choose first or second notice" }, status: :unprocessable_entity unless %w[first second].include?(stage)
    return render json: { error: "TIN mismatch is required before a B-notice" }, status: :unprocessable_entity unless tax.tin_match_status == "mismatch"
    return render json: { error: "First notice must precede second notice" }, status: :unprocessable_entity if stage == "second" && tax.b_notice_stage != "first"
    return render json: { error: "This notice was already recorded" }, status: :unprocessable_entity if tax.b_notice_stage == stage

    sent_on = Date.iso8601(params[:sent_on].to_s)
    return render json: { error: "Sent date cannot be in the future" }, status: :unprocessable_entity if sent_on > Date.current

    tax.update!(b_notice_stage: stage, b_notice_sent_at: sent_on.in_time_zone,
      b_notice_response_due_on: BNotice.business_days_after(sent_on, 30))
    AuditLogger.record!(action: "tax_information.b_notice_sent", auditable: tax, actor: current_user,
      metadata: { stage: stage, sent_on: sent_on, response_due_on: tax.b_notice_response_due_on }, request: request)
    render json: { tax_information: tax.safe_json }
  rescue Date::Error
    render json: { error: "Use an ISO date" }, status: :unprocessable_entity
  end
end
