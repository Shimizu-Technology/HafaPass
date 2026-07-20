# frozen_string_literal: true

class OrganizationContext
  def self.resolve(user:, requested_id: nil)
    return Organization.find_by(id: requested_id) if user.admin? && requested_id.present?

    memberships = user.organization_memberships.effective.includes(:organization).order(:id)
    membership = requested_id.present? ? memberships.find_by(organization_id: requested_id) : memberships.first
    membership&.organization
  end
end
