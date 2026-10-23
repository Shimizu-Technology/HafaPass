# frozen_string_literal: true

# Tenant first, then registry audience, then effective event grants. An event
# manager grant never turns into organization-wide history access.
class OrganizationActivityAccess
  attr_reader :user, :organization

  def initialize(user:, organization:)
    @user = user
    @organization = organization
  end

  def allowed?
    all? || events? || finance? || assigned_event_ids.any?
  end

  def relation
    @relation ||= build_relation
  end

  def build_relation
    tenant = AuditLog.where(organization_id: organization.id)
    started_at = ActivityLogQuery.started_at
    tenant = tenant.where("occurred_at >= ?", started_at) if started_at
    return tenant.where(action: keys("org_owner")) if all?

    visible = tenant.none
    visible = visible.or(tenant.where(action: keys("org_manager"))) if events?
    visible = visible.or(tenant.where(action: keys("org_finance"))) if finance?
    unless events?
      visible = visible.or(tenant.where(action: keys("org_manager"), event_id: assigned_event_ids))
    end
    visible
  end

  def audience_for(action)
    return :org_owner if all?
    return :org_finance if finance? && AuditActions.visible_to?(action, :org_finance)

    :org_manager
  end

  def fingerprint
    Digest::SHA256.hexdigest([organization.id, user.id, all?, events?, finance?, assigned_event_ids.sort].to_json)
  end

  private

  def permitted?(permission)
    @permitted ||= {}
    return @permitted[permission] if @permitted.key?(permission)

    @permitted[permission] = OrganizationAuthorization.allowed?(user: user, organization: organization, permission: permission)
  end

  def all? = permitted?(:view_activity_all)
  def events? = permitted?(:view_activity_events)
  def finance? = permitted?(:view_activity_finance)

  def assigned_event_ids
    @assigned_event_ids ||= if organization.organization_memberships.effective.exists?(user: user)
      organization.event_staff_assignments.effective.where(user: user, role: :manager).pluck(:event_id)
    else
      []
    end
  end

  def keys(audience)
    AuditActions.keys.select { |key| AuditActions.visible_to?(key, audience) }
  end
end
