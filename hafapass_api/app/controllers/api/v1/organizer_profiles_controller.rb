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

      private

      def profile_params
        params.permit(:business_name, :business_description, :logo_url, :is_ambros_partner)
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
          created_at: profile.created_at,
          updated_at: profile.updated_at
        }
      end
    end
  end
end
