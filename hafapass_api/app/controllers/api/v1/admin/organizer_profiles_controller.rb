# frozen_string_literal: true

class Api::V1::Admin::OrganizerProfilesController < Api::V1::Admin::BaseController
  class StaleVerificationRequest < StandardError; end

  def update
    profile = OrganizerProfile.find(params[:id])
    before_data = profile_json(profile)
    previous_status = profile.verification_status
    profile.with_lock do
      if %w[verified rejected].include?(params[:verification_status].to_s) && profile.verification_status_pending? &&
          params[:verification_request_version].to_s != profile.verification_request_version.to_s
        raise StaleVerificationRequest
      end
      apply_verification!(profile) if params[:verification_status].present?
      profile.verification_notes = params[:verification_notes] if params.key?(:verification_notes)
      profile.verification_notes = nil if profile.verification_status_verified? && !params.key?(:verification_notes)
      profile.save!
    end

    AuditLogger.record!(
      action: "organizer.verification_updated",
      auditable: profile,
      actor: current_user,
      organization: profile.organization,
      before_data: before_data,
      after_data: profile_json(profile),
      request: request
    )

    if profile.verification_status != previous_status && %w[verified rejected suspended].include?(profile.verification_status)
      EmailService.send_verification_decision_async(profile)
    end

    render json: profile_json(profile)
  rescue ActiveRecord::RecordInvalid => e
    render json: { errors: e.record.errors.full_messages }, status: :unprocessable_entity
  rescue StaleVerificationRequest
    render json: { error: "This request changed — reload to review the latest details." }, status: :conflict
  end

  private

  def apply_verification!(profile)
    status = params[:verification_status].to_s
    unless OrganizerProfile.verification_statuses.key?(status)
      raise ActiveRecord::RecordInvalid.new(profile.tap { |p| p.errors.add(:verification_status, "is invalid") })
    end

    profile.verification_status = status
    if status == "verified"
      profile.verified_at = Time.current
      profile.verified_by_user = @current_user
    else
      profile.verified_at = nil
      profile.verified_by_user = nil
    end
  end

  def profile_json(profile)
    {
      id: profile.id,
      business_name: profile.business_name,
      verification_status: profile.verification_status,
      verification_requested_at: profile.verification_requested_at,
      verification_request_version: profile.verification_request_version,
      verification_change_diff: profile.verification_change_diff,
      verified_at: profile.verified_at,
      verification_notes: profile.verification_notes,
      verification_phone: profile.verification_phone,
      verification_link: profile.verification_link,
      verification_request_note: profile.verification_request_note,
      published_awaiting_events_count: profile.events.published.count,
      policy_accepted: profile.policy_accepted?,
      payout_ready: profile.organization.payout_ready?
    }
  end
end
