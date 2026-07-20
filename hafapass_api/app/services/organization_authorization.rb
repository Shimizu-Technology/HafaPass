# frozen_string_literal: true

class OrganizationAuthorization
  PERMISSIONS = {
    owner: %i[manage_organization manage_members manage_payout_settings view_events manage_events edit_event_content
      manage_inventory manage_staff view_attendees manage_attendees manage_marketing box_office scan
      view_finance manage_finance refund payout],
    manager: %i[view_events manage_events edit_event_content manage_inventory manage_staff view_attendees view_finance
      manage_attendees manage_marketing box_office scan],
    finance: %i[view_events view_finance manage_finance refund payout],
    marketer: %i[view_events edit_event_content manage_marketing],
    box_office: %i[view_events view_attendees manage_attendees box_office scan],
    scanner: %i[view_events scan]
  }.freeze

  EVENT_ASSIGNMENT_PERMISSIONS = {
    manager: PERMISSIONS.fetch(:manager),
    box_office: PERMISSIONS.fetch(:box_office),
    scanner: PERMISSIONS.fetch(:scanner)
  }.freeze

  ASSIGNMENT_REQUIRED_ROLES = %w[box_office scanner].freeze

  def self.allowed?(**)
    new(**).allowed?
  end

  def self.accessible_events(user:, organization:)
    return organization.events.all if user.admin?

    membership = organization.organization_memberships.effective.find_by(user: user)
    return organization.events.none unless membership
    return organization.events.all unless ASSIGNMENT_REQUIRED_ROLES.include?(membership.role)

    assigned_ids = organization.event_staff_assignments.effective.where(user: user).select(:event_id)
    organization.events.where(id: assigned_ids)
  end

  def initialize(user:, organization:, permission:, event: nil, at: Time.current)
    @user = user
    @organization = organization
    @permission = permission.to_sym
    @event = event
    @at = at
  end

  def allowed?
    return true if user.admin?

    membership = organization.organization_memberships.find_by(user: user)
    return false unless membership&.effective?(at: at)
    return false unless event.nil? || event.organization_id == organization.id

    membership_allowed = role_allowed?(membership.role)
    if event && ASSIGNMENT_REQUIRED_ROLES.include?(membership.role)
      membership_allowed &&= assignment_allowed?(membership.role)
    end
    membership_allowed || assignment_roles.any? { |role| role_allowed?(role, assignment: true) }
  end

  private

  attr_reader :user, :organization, :permission, :event, :at

  def role_allowed?(role, assignment: false)
    matrix = assignment ? EVENT_ASSIGNMENT_PERMISSIONS : PERMISSIONS
    matrix.fetch(role.to_sym, []).include?(permission)
  end

  def assignment_allowed?(role)
    assignment_roles.include?(role)
  end

  def assignment_roles
    return [] unless event

    @assignment_roles ||= event.event_staff_assignments.where(user_id: user.id).effective(at).pluck(:role)
  end
end
