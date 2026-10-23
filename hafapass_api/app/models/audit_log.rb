# frozen_string_literal: true

class AuditLog < ApplicationRecord
  attribute :source, :string, default: "system"
  attribute :outcome, :string, default: "succeeded"
  belongs_to :organization, optional: true
  # Historical event identity survives an event being removed. No cascading FK.
  belongs_to :event, optional: true
  belongs_to :actor_user, class_name: "User", optional: true
  belongs_to :auditable, polymorphic: true

  validates :action, :occurred_at, presence: true
  validates :source, inclusion: { in: %w[user system provider admin] }
  validates :outcome, inclusion: { in: %w[requested succeeded failed unknown] }

  attr_readonly :organization_id, :actor_user_id, :action, :auditable_type, :auditable_id,
    :event_id, :source, :outcome, :deduplication_key,
    :before_data, :after_data, :metadata, :request_id, :ip_address, :occurred_at

  before_update :prevent_mutation
  before_destroy :prevent_mutation

  REDACTABLE_COLUMNS = %w[before_data after_data metadata ip_address retention_anonymized_at updated_at].freeze

  # Intentionally bypasses model callbacks, but never the DB identity guard.
  # SET LOCAL is transaction-scoped (including under Neon's transaction pooler)
  # and the previous value is restored for callers already in a transaction.
  def self.redact!(scope, attributes)
    unknown = attributes.keys.map(&:to_s) - REDACTABLE_COLUMNS
    raise ArgumentError, "Only audit payloads may be redacted" if unknown.any?
    raise ArgumentError, "Expected an AuditLog relation" unless scope.is_a?(ActiveRecord::Relation) && scope.klass == self

    transaction do
      connection = self.connection
      previous = connection.select_value("SELECT current_setting('hafapass.audit_redaction', true)")
      connection.execute("SELECT set_config('hafapass.audit_redaction', 'on', true)")
      begin
        scope.update_all(attributes)
      ensure
        connection.execute("SELECT set_config('hafapass.audit_redaction', #{connection.quote(previous || '')}, true)")
      end
    end
  end

  private

  def prevent_mutation
    errors.add(:base, "Audit logs are append-only")
    throw(:abort)
  end
end
