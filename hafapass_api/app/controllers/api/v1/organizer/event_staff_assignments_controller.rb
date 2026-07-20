# frozen_string_literal: true

class Api::V1::Organizer::EventStaffAssignmentsController < Api::V1::Organizer::BaseController
  before_action :set_event
  before_action :require_staff_management
  before_action :set_assignment, only: [:update, :destroy]

  def index
    candidates = current_organization.organization_memberships.effective.includes(:user).order(:id).filter_map do |membership|
      next unless membership.user

      {
        user_id: membership.user_id,
        email: membership.user.email,
        name: [membership.user.first_name, membership.user.last_name].compact.join(" ").presence,
        organization_role: membership.role
      }
    end
    render json: {
      assignments: @event.event_staff_assignments.includes(:user).order(:id).map { |assignment| assignment_json(assignment) },
      candidates: candidates
    }
  end

  def create
    role = validated_role
    return unless role

    membership = current_organization.organization_memberships.effective.find_by!(user_id: params[:user_id])
    assignment = @event.event_staff_assignments.find_or_initialize_by(user: membership.user, role: role)
    assignment.assign_attributes(
      organization: current_organization,
      assigned_by_user: current_user,
      status: :active,
      expires_at: params[:expires_at]
    )
    assignment.save!
    audit_assignment!("event_staff.assigned", assignment)
    render json: assignment_json(assignment), status: :created
  rescue ActiveRecord::RecordNotFound
    render json: { error: "An active organization member is required" }, status: :unprocessable_entity
  rescue ActiveRecord::RecordInvalid => e
    render json: { errors: e.record.errors.full_messages }, status: :unprocessable_entity
  end

  def update
    role = validated_role
    return unless role

    @assignment.update!(role: role, expires_at: params[:expires_at], status: :active)
    audit_assignment!("event_staff.updated", @assignment)
    render json: assignment_json(@assignment)
  rescue ActiveRecord::RecordInvalid => e
    render json: { errors: e.record.errors.full_messages }, status: :unprocessable_entity
  end

  def destroy
    @assignment.update!(status: :revoked)
    audit_assignment!("event_staff.revoked", @assignment)
    head :no_content
  end

  private

  def set_event
    @event = find_organization_event(params[:event_id])
  end

  def require_staff_management
    authorize_organization!(:manage_staff, event: @event) if @event
  end

  def set_assignment
    @assignment = @event.event_staff_assignments.find(params[:id])
  rescue ActiveRecord::RecordNotFound
    render json: { error: "Staff assignment not found" }, status: :not_found
  end

  def validated_role
    role = params[:role].to_s
    return role if EventStaffAssignment.roles.key?(role)

    render json: { error: "role must be one of: #{EventStaffAssignment.roles.keys.join(", ")}" },
      status: :unprocessable_entity
    nil
  end

  def audit_assignment!(action, assignment)
    AuditLogger.record!(
      action: action,
      auditable: assignment,
      actor: current_user,
      organization: current_organization,
      after_data: assignment_json(assignment),
      request: request
    )
  end

  def assignment_json(assignment)
    {
      id: assignment.id,
      event_id: assignment.event_id,
      user_id: assignment.user_id,
      email: assignment.user.email,
      role: assignment.role,
      status: assignment.status,
      expires_at: assignment.expires_at
    }
  end
end
