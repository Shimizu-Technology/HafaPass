# frozen_string_literal: true

class Api::V1::Admin::CardPresentAccountsController < Api::V1::Admin::BaseController
  def create
    organization = Organization.find(params.require(:organization_id))
    account = organization.build_card_present_account
    apply_attributes!(account)
    account.save!
    audit!(account, {}, account_json(account))
    render json: account_json(account), status: :created
  rescue ActiveRecord::RecordInvalid => e
    render json: { errors: e.record.errors.full_messages }, status: :unprocessable_entity
  end

  def update
    account = CardPresentAccount.find(params[:id])
    before_data = account_json(account)
    apply_attributes!(account)
    account.save!
    audit!(account, before_data, account_json(account))
    render json: account_json(account)
  rescue ActiveRecord::RecordInvalid => e
    render json: { errors: e.record.errors.full_messages }, status: :unprocessable_entity
  end

  private

  def apply_attributes!(account)
    account.assign_attributes(params.permit(:merchant_id, :device_id, :pos_id, :connection_mode))
    status = params[:status].presence
    return unless status

    unless CardPresentAccount.statuses.key?(status)
      account.errors.add(:status, "is invalid")
      raise ActiveRecord::RecordInvalid, account
    end
    account.status = status
    if status == "verified"
      account.verified_at = Time.current
      account.verified_by_user = current_user
      account.verification_evidence = {
        "guam_merchant_approved" => ActiveModel::Type::Boolean.new.cast(params[:guam_merchant_approved]),
        "provider" => "Bank of Hawaii Clover",
        "verification_reference" => params[:verification_reference].to_s.strip,
        "reviewed_at" => Time.current.iso8601
      }
    elsif status != "verified"
      account.verified_at = nil
      account.verified_by_user = nil
      account.verification_evidence = {}
    end
  end

  def account_json(account)
    {
      id: account.id,
      organization_id: account.organization_id,
      provider: account.provider,
      status: account.status,
      payment_ready: account.payment_ready? && CardPresentGateway.configured_for?(account),
      merchant_id: account.merchant_id,
      device_id: account.device_id,
      pos_id: account.pos_id,
      connection_mode: account.connection_mode,
      verified_at: account.verified_at,
      verified_by_user_id: account.verified_by_user_id,
      last_seen_at: account.last_seen_at
    }
  end

  def audit!(account, before_data, after_data)
    AuditLogger.record!(action: "card_present.account_updated", auditable: account, actor: current_user,
      organization: account.organization, before_data: before_data, after_data: after_data, request: request)
  end
end
