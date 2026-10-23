# frozen_string_literal: true

# Read-only, searchable view of the append-only audit trail.
class Api::V1::Admin::AuditLogsController < Api::V1::Admin::BaseController
  include AdminListing

  # GET /api/v1/admin/audit_logs
  def index
    scope = AuditLog.left_joins(:actor_user)
    if (term = search_term)
      pattern = like_pattern(term)
      scope = scope.where("audit_logs.action ILIKE :q OR users.email ILIKE :q OR audit_logs.auditable_type ILIKE :q " \
        "OR audit_logs.request_id = :exact", q: pattern, exact: term)
    end
    if params[:area].present?
      scope = scope.where("audit_logs.action LIKE ?", "#{ActiveRecord::Base.sanitize_sql_like(params[:area].to_s)}.%")
    end
    scope = scope.where(auditable_type: params[:target_type]) if params[:target_type].present?
    scope = scope.where(auditable_id: params[:target_id]) if params[:target_id].present?
    scope = scope.where(organization_id: params[:organization_id]) if params[:organization_id].present?
    if (from = parse_date(params[:from]))
      scope = scope.where("audit_logs.occurred_at >= ?", from.beginning_of_day)
    end
    if (to = parse_date(params[:to]))
      scope = scope.where("audit_logs.occurred_at <= ?", to.end_of_day)
    end
    entries, meta = admin_page(scope.includes(:actor_user, :organization).order(id: :desc))
    render json: {
      audit_logs: entries.map { |entry| entry_json(entry) },
      meta: meta,
      areas: areas
    }
  end

  private

  AREAS_CACHE_KEY = "admin/audit_log_areas"

  # Several services build action names at runtime, so the area list comes
  # from the data. Cache it rather than scanning the table on every request;
  # a selected area always stays in the list.
  def areas
    known = Rails.cache.fetch(AREAS_CACHE_KEY, expires_in: 15.minutes) do
      AuditLog.distinct.pluck(Arel.sql("split_part(action, '.', 1)"))
    end
    (known + [params[:area].presence].compact).uniq.sort
  end

  # Dates are calendar days in the platform's home time zone.
  def parse_date(value)
    Date.iso8601(value.to_s).in_time_zone("Pacific/Guam") if value.present?
  rescue Date::Error
    nil
  end

  def entry_json(entry)
    {
      id: entry.id,
      action: entry.action,
      source: entry.source,
      outcome: entry.outcome,
      event_id: entry.event_id,
      occurred_at: entry.occurred_at,
      actor: user_summary(entry.actor_user),
      target: { type: entry.auditable_type, id: entry.auditable_id },
      organization: entry.organization && { id: entry.organization_id, name: entry.organization.name },
      before_data: AuditSanitizer.call(entry.before_data),
      after_data: AuditSanitizer.call(entry.after_data),
      metadata: AuditSanitizer.call(entry.metadata),
      request_id: entry.request_id
    }
  end
end
