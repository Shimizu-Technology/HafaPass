# frozen_string_literal: true

class Api::V1::Organizer::FeeChangeNoticesController < Api::V1::Organizer::BaseController
  def acknowledge
    membership = current_user.organization_memberships.effective.find_by(organization: current_organization, role: :owner)
    return render json: { error: "Owner permission required" }, status: :forbidden unless membership

    notice = FeeChangeNotice.joins(:fee_change).where(organization: current_organization, owner: current_user,
      fee_changes: { activated_at: nil }).find(params[:id])
    notice.with_lock do
      if notice.acknowledged_at.nil?
        notice.update!(acknowledged_at: Time.current)
        AuditLogger.record!(action: "site_settings.fee_change_acknowledged", auditable: notice,
          actor: current_user, organization: current_organization,
          metadata: { fee_change_id: notice.fee_change_id }, request: request)
      end
    end
    render json: { acknowledged_at: notice.acknowledged_at }
  end
end
