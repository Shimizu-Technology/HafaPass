# frozen_string_literal: true

# The organizer representation is deliberately constructed, never an AuditLog
# as_json with a blacklist. Templates are fixed registry text; private values
# cannot be interpolated into a sentence.
class ActivityLogPresenter
  def initialize(entry, organization: nil, member_ids: nil)
    @entry = entry
    @organization = organization
    @member_ids = member_ids
  end

  def organization_json
    { id: entry.id, occurred_at: entry.occurred_at, sentence: definition[:template],
      area: definition[:area], outcome: entry.outcome || "unknown", actor: actor,
      event: event_json, target: target, changes: changes }
  end

  def admin_json
    organization_json.merge(action: entry.action, source: entry.source, event_id: entry.event_id,
      actor_user_id: entry.actor_user_id, actor: admin_actor,
      organization: entry.organization && { id: entry.organization_id, name: entry.organization.name,
        url: "/admin/organizations/#{entry.organization_id}" },
      target: { type: entry.auditable_type, id: entry.auditable_id },
      before_data: AuditSanitizer.call(entry.before_data), after_data: AuditSanitizer.call(entry.after_data),
      metadata: AuditSanitizer.call(entry.metadata), request_id: AuditSanitizer.call(entry.request_id))
  end

  private

  attr_reader :entry, :organization

  def definition = AuditActions.fetch(entry.action)

  def actor
    return { name: "Stripe" } if entry.source == "provider"
    return { name: "HåfaPass" } if entry.source == "system"
    return { name: "HåfaPass administrator" } if entry.source == "admin" || entry.actor_user&.staff?
    return { name: "System" } unless entry.actor_user

    member = @member_ids ? @member_ids.include?(entry.actor_user_id) :
      organization&.organization_memberships&.effective&.exists?(user_id: entry.actor_user_id)
    return { name: "Buyer" } unless member

    { name: full_name(entry.actor_user).presence || entry.actor_user.email, email: entry.actor_user.email }
  end

  def admin_actor
    return nil unless entry.actor_user

    { id: entry.actor_user_id, name: full_name(entry.actor_user).presence, email: entry.actor_user.email }
  end

  def full_name(user) = [user.first_name, user.last_name].compact_blank.join(" ")

  def event_json
    event = entry.event
    return unless event && (!organization || event.organization_id == organization.id)

    { id: event.id, title: event.title, url: organization ? "/dashboard/events/#{event.id}" : "/admin/events/#{event.id}" }
  end

  # Event pages are useful, permission-safe targets. Avoid buyer/order links:
  # the audience for a history summary does not grant access to its subject.
  def target
    return unless event_json

    { label: "View event", url: event_json[:url] }
  end

  def changes
    safe = AuditActions.organization_payload(entry.action, before_data: entry.before_data, after_data: entry.after_data)
    before = safe[:before_data]
    after = safe[:after_data]
    (before.keys | after.keys).filter_map do |field|
      next if before[field] == after[field]

      { field: field.humanize, before: before[field], after: after[field] }
    end
  end
end
