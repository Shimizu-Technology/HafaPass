module Api
  module V1
    class MeController < ApplicationController
      def show
        ClerkProfileSync.call(current_user)
        applied = PlatformInvitations.apply_pending_for!(current_user, request: request)
        current_user.reload if applied.any?
        render json: {
          id: current_user.id,
          clerk_id: current_user.clerk_id,
          email: current_user.email,
          first_name: current_user.first_name,
          last_name: current_user.last_name,
          phone: current_user.phone,
          role: current_user.role,
          workspace: workspace_json
        }
      end

      private

      # What the navigation may offer. Authorization still happens on every
      # request; this only keeps people from seeing tools they cannot use.
      def workspace_json
        return { organizations: Organization.count, organizer: true, scanner: true } if current_user.admin?

        memberships = current_user.organization_memberships.effective
        roles = memberships.pluck(:role)
        scanner = roles.intersect?(%w[owner manager]) ||
          current_user.event_staff_assignments.effective
            .where(organization_id: memberships.select(:organization_id)).exists?
        { organizations: roles.size, organizer: roles.any?, scanner: scanner }
      end
    end
  end
end
