module Api
  module V1
    class OrganizerProfilesController < ApplicationController
      def show
        profile = current_user.organizer_profile
        if profile
          render json: profile_json(profile)
        else
          render json: { error: "Organizer profile not found" }, status: :not_found
        end
      end

      def create_or_update
        profile = current_user.organizer_profile || current_user.build_organizer_profile

        profile.assign_attributes(profile_params)

        if profile.save
          # Promote user to organizer role if they're still an attendee
          current_user.update!(role: :organizer) if current_user.attendee?

          status = profile.previously_new_record? ? :created : :ok
          render json: profile_json(profile), status: status
        else
          render json: { errors: profile.errors.full_messages }, status: :unprocessable_entity
        end
      end

      def accept_policy
        profile = current_user.organizer_profile
        return render json: { error: "Organizer profile not found" }, status: :not_found unless profile

        profile.update!(policy_accepted_at: Time.current)
        render json: profile_json(profile)
      end

      def submit_verification
        profile = current_user.organizer_profile
        return render json: { error: "Organizer profile not found" }, status: :not_found unless profile

        unless profile.business_name.present? && profile.business_description.present?
          return render json: { error: "Add a business name and description before requesting verification" },
            status: :unprocessable_entity
        end

        if profile.verification_status_verified? || profile.verification_status_suspended?
          return render json: { error: "This organizer profile cannot be submitted for verification" },
            status: :unprocessable_entity
        end

        profile.update!(verification_status: :pending, verification_requested_at: Time.current, verification_notes: nil)
        render json: profile_json(profile)
      end

      private

      def profile_params
        params.permit(:business_name, :business_description, :logo_url)
      end

      def profile_json(profile)
        {
          id: profile.id,
          user_id: profile.user_id,
          business_name: profile.business_name,
          business_description: profile.business_description,
          logo_url: profile.logo_url,
          stripe_account_id: profile.stripe_account_id,
          is_ambros_partner: profile.is_ambros_partner,
          verification_status: profile.verification_status,
          verification_requested_at: profile.verification_requested_at,
          verified_at: profile.verified_at,
          verification_notes: profile.verification_notes,
          policy_accepted_at: profile.policy_accepted_at,
          policy_accepted: profile.policy_accepted?,
          payout_ready: profile.payout_ready,
          ready_to_publish_free_events: profile.ready_to_publish_free_events?,
          ready_to_publish_paid_events: profile.ready_to_publish_paid_events?,
          created_at: profile.created_at,
          updated_at: profile.updated_at
        }
      end
    end
  end
end
