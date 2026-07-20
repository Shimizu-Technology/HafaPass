# frozen_string_literal: true

class AuditLogger
  def self.record!(action:, auditable:, actor: nil, organization: nil, before_data: {}, after_data: {}, metadata: {}, request: nil)
    AuditLog.create!(
      organization: organization || inferred_organization(auditable),
      actor_user: actor,
      action: action,
      auditable: auditable,
      before_data: before_data,
      after_data: after_data,
      metadata: metadata,
      request_id: request&.request_id,
      ip_address: request&.remote_ip,
      occurred_at: Time.current
    )
  end

  def self.inferred_organization(auditable)
    return auditable if auditable.is_a?(Organization)
    return auditable.organization if auditable.respond_to?(:organization)

    nil
  end
  private_class_method :inferred_organization
end
