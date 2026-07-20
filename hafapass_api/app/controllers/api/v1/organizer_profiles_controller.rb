module Api
  module V1
    class OrganizerProfilesController < ApplicationController
      def show
        profile = current_profile
        if profile
          render json: profile_json(profile)
        else
          render json: { error: "Organizer profile not found" }, status: :not_found
        end
      end

      def create_or_update
        profile = current_profile
        created = profile.nil?
        if profile && !OrganizationAuthorization.allowed?(
          user: current_user, organization: profile.organization, permission: :manage_organization
        )
          return render json: { error: "Owner permission required" }, status: :forbidden
        end

        ActiveRecord::Base.transaction do
          if created
            organization = Organization.create!(name: profile_params[:business_name])
            profile = current_user.build_organizer_profile(profile_params.to_h.merge(organization: organization))
            profile.save!
            organization.organization_memberships.create!(
              user: current_user, role: :owner, status: :active, accepted_at: Time.current
            )
          else
            profile.update!(profile_params)
            profile.organization.update!(name: profile.business_name)
          end
          current_user.update!(role: :organizer) if current_user.attendee?
          AuditLogger.record!(
            action: created ? "organization.created" : "organization.updated",
            auditable: profile.organization,
            actor: current_user,
            after_data: profile_params.to_h,
            request: request
          )
        end

        if profile.persisted?
          status = created ? :created : :ok
          render json: profile_json(profile), status: status
        end
      rescue ActiveRecord::RecordInvalid => e
        render json: { errors: e.record.errors.full_messages }, status: :unprocessable_entity
      end

      def accept_policy
        profile = current_profile
        return render json: { error: "Organizer profile not found" }, status: :not_found unless profile
        return render json: { error: "Owner permission required" }, status: :forbidden unless owner?(profile)

        profile.update!(policy_accepted_at: Time.current)
        AuditLogger.record!(action: "organizer.policy_accepted", auditable: profile, actor: current_user, request: request)
        render json: profile_json(profile)
      end

      def submit_verification
        profile = current_profile
        return render json: { error: "Organizer profile not found" }, status: :not_found unless profile
        return render json: { error: "Owner permission required" }, status: :forbidden unless owner?(profile)

        unless profile.business_name.present? && profile.business_description.present?
          return render json: { error: "Add a business name and description before requesting verification" },
            status: :unprocessable_entity
        end

        if profile.verification_status_verified? || profile.verification_status_suspended?
          return render json: { error: "This organizer profile cannot be submitted for verification" },
            status: :unprocessable_entity
        end

        profile.update!(verification_status: :pending, verification_requested_at: Time.current, verification_notes: nil)
        AuditLogger.record!(action: "organizer.verification_requested", auditable: profile, actor: current_user,
          request: request)
        render json: profile_json(profile)
      end

      private

      def profile_params
        params.permit(:business_name, :business_description, :logo_url)
      end

      def current_profile
        organization = OrganizationContext.resolve(
          user: current_user,
          requested_id: request.headers["X-Organization-Id"].presence
        )
        organization&.organizer_profile || current_user.organizer_profile
      end

      def owner?(profile)
        OrganizationAuthorization.allowed?(
          user: current_user, organization: profile.organization, permission: :manage_organization
        )
      end

      def financial_access?(profile)
        OrganizationAuthorization.allowed?(
          user: current_user, organization: profile.organization, permission: :view_finance
        )
      end

      def profile_json(profile)
        {
          id: profile.id,
          organization: {
            id: profile.organization.id,
            name: profile.organization.name,
            slug: profile.organization.slug,
            status: profile.organization.status,
            role: profile.organization.organization_memberships.find_by(user: current_user)&.role
          },
          business_name: profile.business_name,
          business_description: profile.business_description,
          logo_url: profile.logo_url,
          is_ambros_partner: profile.is_ambros_partner,
          verification_status: profile.verification_status,
          verification_requested_at: profile.verification_requested_at,
          verified_at: profile.verified_at,
          verification_notes: owner?(profile) ? profile.verification_notes : nil,
          policy_accepted_at: profile.policy_accepted_at,
          policy_accepted: profile.policy_accepted?,
          payout_ready: profile.organization.payout_ready?,
          connected_account: financial_access?(profile) ? connected_account_json(
            profile.organization.payout_account || profile.organization.connected_accounts.first
          ) : nil,
          ready_to_publish_free_events: profile.ready_to_publish_free_events?,
          ready_to_publish_paid_events: profile.ready_to_publish_paid_events?,
          created_at: profile.created_at,
          updated_at: profile.updated_at
        }
      end
      def connected_account_json(account)
        return unless account

        {
          id: account.id,
          provider: account.provider,
          status: account.status,
          charges_enabled: account.charges_enabled,
          payouts_enabled: account.payouts_enabled,
          details_submitted: account.details_submitted,
          requirements_due: account.requirements_due,
          payout_ready: account.payout_ready?
        }
      end
    end
  end
end
