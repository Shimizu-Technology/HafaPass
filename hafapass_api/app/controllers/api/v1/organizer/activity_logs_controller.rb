# frozen_string_literal: true

class Api::V1::Organizer::ActivityLogsController < Api::V1::Organizer::BaseController
  def index
    access = OrganizationActivityAccess.new(user: current_user, organization: current_organization)
    return render json: { error: "You do not have permission to view activity" }, status: :forbidden unless access.allowed?

    query = ActivityLogQuery.new(scope: access.relation, organization: current_organization, params: params)
    entries, cursor = query.page(cursor: params[:cursor], limit: params[:limit], identity: [current_user.id, current_organization.id, access.fingerprint])
    members = current_organization.organization_memberships.effective.where.not(user_id: nil).pluck(:user_id).to_set
    actor_ids = access.relation.where.not(actor_user_id: nil).distinct.pluck(:actor_user_id)
    actors = User.where(id: actor_ids).order(:id).filter_map do |person|
      next unless members.include?(person.id) || person.staff?

      person.staff? ? { id: person.id, name: "HåfaPass administrator" } :
        { id: person.id, name: [person.first_name, person.last_name].compact_blank.join(" ").presence || person.email, email: person.email }
    end
    response.headers["Cache-Control"] = "no-store"
    render json: { activity_logs: entries.map { |entry| ActivityLogPresenter.new(entry, organization: current_organization, member_ids: members).organization_json },
      meta: { next_cursor: cursor, activity_logging_started_at: ActivityLogQuery.started_at },
      filters: { actors: actors, areas: access.relation.distinct.pluck(:action).map { |key| AuditActions.fetch(key)[:area] }.uniq.sort,
        events: current_organization.events.where(id: access.relation.where.not(event_id: nil).select(:event_id)).order(:title).pluck(:id, :title).map { |id, title| { id: id, title: title } } } }
  rescue ActivityLogQuery::InvalidFilter => error
    render json: { error: error.message }, status: :unprocessable_entity
  end
end
