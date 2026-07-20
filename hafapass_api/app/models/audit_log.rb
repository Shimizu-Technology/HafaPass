# frozen_string_literal: true

class AuditLog < ApplicationRecord
  belongs_to :organization, optional: true
  belongs_to :actor_user, class_name: "User", optional: true
  belongs_to :auditable, polymorphic: true

  validates :action, :occurred_at, presence: true

  attr_readonly :organization_id, :actor_user_id, :action, :auditable_type, :auditable_id,
    :before_data, :after_data, :metadata, :request_id, :ip_address, :occurred_at

  before_update :prevent_mutation
  before_destroy :prevent_mutation

  private

  def prevent_mutation
    errors.add(:base, "Audit logs are append-only")
    throw(:abort)
  end
end
