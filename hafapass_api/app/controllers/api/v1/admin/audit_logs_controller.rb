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
      areas: AuditLog.distinct.pluck(Arel.sql("split_part(action, '.', 1)")).sort
    }
  end

  private

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
      occurred_at: entry.occurred_at,
      actor: user_summary(entry.actor_user),
      target: { type: entry.auditable_type, id: entry.auditable_id },
      organization: entry.organization && { id: entry.organization_id, name: entry.organization.name },
      before_data: entry.before_data,
      after_data: entry.after_data,
      metadata: entry.metadata,
      request_id: entry.request_id
    }
  end
end
