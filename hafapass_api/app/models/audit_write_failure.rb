# frozen_string_literal: true

# Minimal durable gap marker. No snapshots, exception messages, request details,
# contacts or provider payloads; no FK can erase historical identities.
class AuditWriteFailure < ApplicationRecord
  def self.capture!(attributes, error)
    subject = attributes.fetch(:auditable)
    event = attributes[:event] || AuditLogger.send(:related, subject, Event)
    organization = attributes[:organization] || AuditLogger.send(:related, subject, Organization) || event&.organization
    actor = attributes[:actor] || AuditContext.actor
    identity = { action: attributes.fetch(:action), auditable_type: subject.class.polymorphic_name,
      auditable_id: subject.id, organization_id: organization&.id, event_id: event&.id,
      actor_user_id: actor&.id, source: attributes[:source] || AuditContext.source || (actor ? (actor.admin? ? "admin" : "user") : "system"),
      failure_class: error.class.name }
    report(identity)
    transaction(requires_new: true) { create!(identity) }
  rescue StandardError => marker_error
    # Monitoring and fallback storage are independently best effort. Neither may
    # turn an accepted payment or admission into a business failure.
    report({ action: attributes[:action], auditable_id: attributes[:auditable]&.id,
      failure_class: marker_error.class.name, fallback_failed: true })
    nil
  end

  def self.report(identity)
    Rails.logger.error({ event: "audit_write_failed", **identity }.to_json)
    Sentry.capture_exception(AuditLogger::WriteError.new("Audit write failed"), extra: identity)
  rescue StandardError
    nil
  end
  private_class_method :report
end
