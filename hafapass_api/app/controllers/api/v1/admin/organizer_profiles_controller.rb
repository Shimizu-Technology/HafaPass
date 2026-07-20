# frozen_string_literal: true

class Api::V1::Admin::OrganizerProfilesController < Api::V1::Admin::BaseController
  def update
    profile = OrganizerProfile.find(params[:id])
    profile.with_lock do
      apply_verification!(profile) if params[:verification_status].present?
      profile.payout_ready = ActiveModel::Type::Boolean.new.cast(params[:payout_ready]) if params.key?(:payout_ready)
      profile.verification_notes = params[:verification_notes] if params.key?(:verification_notes)
      profile.save!
    end

    render json: profile_json(profile)
  rescue ActiveRecord::RecordInvalid => e
    render json: { errors: e.record.errors.full_messages }, status: :unprocessable_entity
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
      verified_at: profile.verified_at,
      verification_notes: profile.verification_notes,
      policy_accepted: profile.policy_accepted?,
      payout_ready: profile.payout_ready
    }
  end
end
