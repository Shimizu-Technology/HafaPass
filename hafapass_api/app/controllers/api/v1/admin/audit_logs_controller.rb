# frozen_string_literal: true

class Api::V1::Admin::AuditLogsController < Api::V1::Admin::BaseController
  include AdminListing

  def index
    query = ActivityLogQuery.new(scope: AuditLog.all, params: request.query_parameters, admin: true)
    entries, meta = admin_page(query.relation.includes(:actor_user, :organization, :event).order(id: :desc))
    response.headers["Cache-Control"] = "no-store"
    render json: { audit_logs: entries.map { |entry| ActivityLogPresenter.new(entry).admin_json },
      meta: meta, areas: AuditActions::AREAS.sort,
      filters: { organizations: Organization.order(:name).pluck(:id, :name).map { |id, name| { id: id, name: name } },
        actors: User.where(id: AuditLog.select(:actor_user_id)).order(:email).map { |person| user_summary(person) },
        events: Event.where(id: AuditLog.select(:event_id)).order(:title).pluck(:id, :title).map { |id, title| { id: id, title: title } },
        actions: AuditLog.distinct.order(:action).pluck(:action) } }
  rescue ActivityLogQuery::InvalidFilter => error
    render json: { error: error.message }, status: :unprocessable_entity
  end
end
