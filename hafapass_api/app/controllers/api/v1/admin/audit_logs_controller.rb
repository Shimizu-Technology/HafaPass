# frozen_string_literal: true

class Api::V1::Admin::AuditLogsController < Api::V1::Admin::BaseController
  include AdminListing

  def index
    query = ActivityLogQuery.new(scope: AuditLog.all, params: request.query_parameters, admin: true)
    entries, meta = admin_page(query.relation.includes(:actor_user, :organization, :event).order(id: :desc))
    response.headers["Cache-Control"] = "no-store"
    render json: { audit_logs: entries.map { |entry| ActivityLogPresenter.new(entry).admin_json },
      meta: meta, areas: AuditActions::AREAS.sort,
      filters: (params[:page].to_i <= 1 || params[:include_filters] == "true") ? filter_options(query) : nil }.compact
  rescue ActivityLogQuery::InvalidFilter => error
    render json: { error: error.message }, status: :unprocessable_entity
  end
  private

  # Cache bounded identifiers, never contact details: privacy edits and deleted
  # records are reflected when names are read for the response.
  def filter_options(query)
    cache_key = ["admin-activity-options-v1", Digest::SHA256.hexdigest(query.filters.sort.to_json)]
    ids = Rails.cache.fetch(cache_key, expires_in: 1.minute) do
      scope = query.relation
      { organizations: scope.where.not(organization_id: nil).distinct.limit(500).pluck(:organization_id),
        actors: scope.where.not(actor_user_id: nil).distinct.limit(500).pluck(:actor_user_id),
        events: scope.where.not(event_id: nil).distinct.limit(500).pluck(:event_id),
        actions: scope.distinct.order(:action).limit(500).pluck(:action) }
    end
    { organizations: Organization.where(id: ids[:organizations]).order(:name).pluck(:id, :name).map { |id, name| { id: id, name: name } },
      actors: User.where(id: ids[:actors]).select(:id, :email, :first_name, :last_name).order(:email).map { |person| user_summary(person) },
      events: Event.where(id: ids[:events]).order(:title).pluck(:id, :title).map { |id, title| { id: id, title: title } },
      actions: ids[:actions] }
  end
end
