# frozen_string_literal: true

class ActivityLogQuery
  class InvalidFilter < StandardError; end
  FILTERS = %w[from to actor_user_id area event_id outcome q organization_id action source target_type target_id].freeze
  OUTCOMES = %w[requested succeeded failed unknown].freeze
  SOURCES = %w[user system provider admin].freeze

  attr_reader :filters, :base, :organization

  def initialize(scope:, params:, organization: nil, admin: false)
    @base = scope
    @organization = organization
    @admin = admin
    @filters = FILTERS.index_with { |key| params[key].to_s.strip.presence }.compact
    @filters.except!("organization_id", "action", "source", "target_type", "target_id") unless admin
    validate!
  end

  def relation
    result = base
    %w[actor_user_id event_id].each { |key| result = result.where(key => filters[key]) if filters[key] }
    if filters["actor_user_id"] && organization && !@admin
      # Staff and buyers have deliberately shared display identities. Exact
      # actor filters must not let guessed IDs undo that masking.
      members = organization.organization_memberships.effective.where(user_id: User.where.not(role: [:admin, :support])).select(:user_id)
      result = result.where(actor_user_id: members)
    end
    if filters["outcome"]
      result = result.where(outcome: filters["outcome"] == "unknown" ? [nil, "unknown"] : filters["outcome"])
    end
    if @admin
      %w[organization_id action source auditable_type auditable_id].each do |key|
        input = { "auditable_type" => "target_type", "auditable_id" => "target_id" }.fetch(key, key)
        result = result.where(key => filters[input]) if filters[input]
      end
    end
    if filters["area"]
      area = result.where(action: AuditActions.keys.select { |key| AuditActions.fetch(key)[:area] == filters["area"] })
      # Unknown actions use the registry's private platform fallback. They
      # remain visible to admins under the area displayed on their row.
      area = area.or(result.where.not(action: AuditActions.keys)) if @admin && filters["area"] == "platform"
      result = area
    end
    result = result.where("audit_logs.occurred_at >= ?", day("from")) if filters["from"]
    result = result.where("audit_logs.occurred_at < ?", day("to") + 1.day) if filters["to"]
    filters["q"] ? search(result) : result
  end

  def page(cursor: nil, limit: nil, identity:)
    size = limit.to_i.positive? ? [limit.to_i, 100].min : 50
    signature = Digest::SHA256.hexdigest([identity, filters.sort].to_json)
    boundary = cursor.present? ? verifier.verified(cursor, purpose: "activity-page") : nil
    raise InvalidFilter, "Invalid or expired activity cursor" if cursor.present? && (!boundary || boundary["signature"] != signature)

    ceiling = boundary ? boundary.fetch("ceiling") : (base.maximum(:id) || 0)
    result = relation.where("audit_logs.id <= ?", ceiling)
    if boundary
      result = result.where("(audit_logs.occurred_at, audit_logs.id) < (?, ?)", Time.iso8601(boundary.fetch("time")), boundary.fetch("id"))
    end
    records = result.includes(:actor_user, :organization, :event).order(occurred_at: :desc, id: :desc).limit(size + 1).to_a
    has_more = records.length > size
    records = records.first(size)
    last = records.last
    next_cursor = verifier.generate({ signature: signature, ceiling: ceiling, time: last.occurred_at.iso8601(6), id: last.id },
      purpose: "activity-page", expires_in: 1.day) if has_more
    [records, next_cursor]
  rescue KeyError, ArgumentError
    raise InvalidFilter, "Invalid activity cursor"
  end

  def self.started_at
    AuditLog.where(action: "platform.activity_logging_started").minimum(:occurred_at)
  end

  private

  def verifier = Rails.application.message_verifier("activity-logs")

  def day(key)
    Date.iso8601(filters.fetch(key)).in_time_zone("Pacific/Guam")
  rescue Date::Error
    raise InvalidFilter, "Use YYYY-MM-DD for activity dates"
  end

  def validate!
    day("from") if filters["from"]
    day("to") if filters["to"]
    raise InvalidFilter, "End date must follow start date" if filters["from"] && filters["to"] && day("to") < day("from")
    raise InvalidFilter, "Unknown activity outcome" if filters["outcome"] && !OUTCOMES.include?(filters["outcome"])
    raise InvalidFilter, "Unknown activity source" if filters["source"] && !SOURCES.include?(filters["source"])
    raise InvalidFilter, "Unknown activity area" if filters["area"] && !AuditActions::AREAS.include?(filters["area"])
    %w[actor_user_id event_id organization_id target_id].each do |key|
      raise InvalidFilter, "Invalid activity #{key.humanize.downcase}" if filters[key] && !filters[key].match?(/\A[1-9]\d*\z/)
    end
    filters["q"] = filters["q"].first(200) if filters["q"]
  end

  def search(result)
    term = filters.fetch("q")
    pattern = "%#{ActiveRecord::Base.sanitize_sql_like(term)}%"
    if @admin
      return result.left_joins(:actor_user, :event, :organization).where(
        "audit_logs.action ILIKE :q OR users.email ILIKE :q OR audit_logs.auditable_type ILIKE :q " \
        "OR audit_logs.request_id = :exact OR events.title ILIKE :q OR organizations.name ILIKE :q", q: pattern, exact: term)
    end

    # Search only displayed sentences, areas, event titles and safe actor labels.
    # Only registry-allowlisted display context is searched in JSON; never
    # private payloads, buyer contacts, internal action/target/request IDs.
    matching_actions = AuditActions.keys.select do |key|
      definition = AuditActions.fetch(key)
      [definition[:template], definition[:area]].any? { |text| text.downcase.include?(term.downcase) }
    end
    member_ids = organization.organization_memberships.effective.where(user_id: User.where.not(role: [:admin, :support])
      .where("concat_ws(' ', first_name, last_name) ILIKE :q OR email ILIKE :q", q: pattern)).select(:user_id)
    labels = { "provider" => "Stripe", "system" => "HåfaPass", "admin" => "HåfaPass administrator" }
      .select { |_source, name| name.downcase.include?(term.downcase) }.keys
    matching_events = organization.events.where("title ILIKE ?", pattern).select(:id)
    matches = result.where(action: matching_actions).or(result.where(event_id: matching_events))
      .or(result.where(source: "user", actor_user_id: member_ids)).or(result.where(source: labels))
    AuditActions::DISPLAY_FIELDS.each do |key|
      actions = AuditActions.keys.select { |action| AuditActions.fetch(action)[:organization_fields][:metadata].include?(key) }
      matches = matches.or(result.where(action: actions).where(
        "jsonb_typeof(audit_logs.metadata -> ?) = 'string' AND audit_logs.metadata ->> ? ILIKE ?", key, key, pattern))
    end
    matches
  end
end
