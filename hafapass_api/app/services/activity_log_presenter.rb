# frozen_string_literal: true

# The organizer representation is deliberately constructed, never an AuditLog
# as_json with a blacklist. Sentences interpolate only registry-allowlisted
# scalar snapshots, never the private audit payload.
class ActivityLogPresenter
  def initialize(entry, organization: nil, member_ids: nil, audience: :org_owner)
    @entry = entry
    @organization = organization
    @member_ids = member_ids
    @audience = audience
  end

  def organization_json
    { id: entry.id, occurred_at: entry.occurred_at, sentence: sentence,
      area: definition[:area], outcome: entry.outcome || "unknown", actor: actor,
      event: event_json, target: target, changes: changes }
  end

  def admin_json
    organization_json.merge(action: entry.action, source: entry.source, event_id: entry.event_id,
      actor_user_id: entry.actor_user_id, actor: admin_actor, sentence: sentence(actor_name: admin_actor&.dig(:name).presence || admin_actor&.dig(:email).presence || actor[:name]),
      organization: entry.organization && { id: entry.organization_id, name: entry.organization.name,
        url: "/admin/organizations/#{entry.organization_id}" },
      target: { type: entry.auditable_type, id: entry.auditable_id },
      before_data: AuditSanitizer.call(entry.before_data), after_data: AuditSanitizer.call(entry.after_data),
      metadata: AuditSanitizer.call(entry.metadata), request_id: AuditSanitizer.call(entry.request_id))
  end

  # Searchable text is built from exactly the labels and values returned to
  # this viewer, never from stored-but-undisplayed metadata or identifiers.
  def search_text
    data = organization_json
    area_label = { "scanning" => "Check-in", "door" => "Door sales", "attendees" => "Guest list", "messaging" => "Campaigns" }.fetch(data[:area], data[:area].humanize)
    outcome_label = data[:outcome] == "unknown" ? "Needs review" : data[:outcome].humanize
    [data[:sentence], area_label, outcome_label, data[:actor].values,
      data[:event]&.dig(:title), data[:target]&.dig(:label),
      data[:changes].flat_map { |change| change.values }].flatten.compact.join(" ")
  end

  private

  attr_reader :entry, :organization

  def definition = AuditActions.fetch(entry.action)

  def sentence(actor_name: actor[:name])
    ActivityLogSentence.new(entry, actor_name: actor_name, audience: @audience).call
  end

  def actor
    return { name: "Stripe" } if entry.source == "provider"
    return { name: "HåfaPass" } if entry.source == "system"
    return { name: "HåfaPass administrator" } if entry.source == "admin" || entry.actor_user&.staff?
    if entry.source == "user" && !entry.actor_user
      return { name: entry.actor_user_id ? "Former user" : "Buyer" }
    end
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
    safe = AuditActions.organization_payload(entry.action, audience: @audience, before_data: entry.before_data, after_data: entry.after_data)
    before = safe[:before_data]
    after = safe[:after_data]
    (before.keys | after.keys).filter_map do |field|
      next if before[field] == after[field]

      { field: field.humanize, before: before[field], after: after[field] }
    end
  end
end
