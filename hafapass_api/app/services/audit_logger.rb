# frozen_string_literal: true

class AuditLogger
  # Business validation handlers must not turn a rejected audit into a 422 that
  # commits a privileged mutation in an enclosing transaction.
  class WriteError < StandardError; end

  def self.record!(action:, auditable:, actor: nil, organization: nil, event: nil, before_data: {}, after_data: {}, metadata: {}, request: nil,
    source: nil, outcome: nil, deduplication_key: nil)
    inferred_event = related(auditable, Event)
    inferred_organization = related(auditable, Organization)
    event ||= inferred_event
    organization ||= inferred_organization || event&.organization
    if inferred_organization && organization && inferred_organization.id != organization.id
      raise ArgumentError, "Audit organization does not match its subject"
    end
    if event && organization && event.organization_id != organization.id
      raise ArgumentError, "Audit event does not belong to its organization"
    end
    if inferred_event && event && inferred_event.id != event.id
      raise ArgumentError, "Audit event does not match its subject"
    end
    if AuditActions.tenant?(action) && organization.nil?
      raise ArgumentError, "Organization is required for #{action}"
    end
    if AuditActions.event_required?(action) && event.nil?
      raise ArgumentError, "Event is required for #{action}"
    end
    actor ||= AuditContext.actor
    attributes = {
      organization: organization,
      event: event,
      actor_user: actor,
      action: action,
      auditable: auditable,
      source: source || AuditContext.source || (actor ? (actor.admin? ? "admin" : "user") : "system"),
      outcome: outcome || (action.end_with?("failed") ? "failed" : (action.end_with?("requested") ? "requested" : "succeeded")),
      before_data: AuditSanitizer.call(before_data),
      after_data: AuditSanitizer.call(after_data),
      metadata: AuditSanitizer.call(metadata),
      request_id: AuditSanitizer.call(request&.request_id || AuditContext.request_id),
      ip_address: request&.remote_ip || AuditContext.ip_address,
      occurred_at: Time.current
    }
    return AuditLog.create!(attributes) if deduplication_key.blank?

    # A savepoint lets a concurrent unique-index conflict be recovered without
    # poisoning the caller's mutation transaction. Never swallow audit errors.
    AuditLog.create_or_find_by!(action: action, deduplication_key: deduplication_key) do |entry|
      entry.assign_attributes(attributes)
    end.tap do |entry|
      unless entry.organization_id == organization&.id && entry.event_id == event&.id &&
          entry.auditable_type == auditable.class.polymorphic_name && entry.auditable_id == auditable.id
        raise ArgumentError, "Audit retry key belongs to a different subject"
      end
    end
  rescue ActiveRecord::RecordInvalid => error
    raise WriteError, "Audit record could not be saved", cause: error
  end

  def self.related(record, type, seen = [])
    return if record.nil? || seen.include?([record.class.name, record.id])
    return record if record.is_a?(type)

    seen = seen + [[record.class.name, record.id]]
    associations = type == Event ? [:event, :order, :ticket, :ticket_type, :order_item, :payment, :refund, :communication_campaign] :
      [:organization, :event, :order, :ticket, :ticket_type, :order_item, :payment, :refund, :organization_membership, :communication_campaign,
        :venue_layout, :seating_section, :seating_row]
    associations.each do |association|
      next unless record.respond_to?(association)

      found = related(record.public_send(association), type, seen)
      return found if found
    end
    nil
  end
  private_class_method :related
end
