module Api
  module V1
    class UsersController < ApplicationController
      skip_before_action :authenticate_user!, only: [:sync]

      def sync
        clerk_id = sync_params[:clerk_id] || sync_params[:id]
        if clerk_id.blank?
          render json: { error: "clerk_id or id is required" }, status: :unprocessable_entity
          return
        end

        user = User.find_or_initialize_by(clerk_id: clerk_id)
        user.assign_attributes(
          email: sync_params[:email] || sync_params.dig(:email_addresses, 0, :email_address),
          first_name: sync_params[:first_name],
          last_name: sync_params[:last_name],
          phone: sync_params[:phone] || sync_params.dig(:phone_numbers, 0, :phone_number)
        )

        # First user created becomes admin
        if user.new_record? && User.count.zero?
          user.role = :admin
        end

        if user.save
          render json: {
            id: user.id,
            clerk_id: user.clerk_id,
            email: user.email,
            first_name: user.first_name,
            last_name: user.last_name,
            phone: user.phone,
            role: user.role,
            created_at: user.created_at,
            updated_at: user.updated_at
          }, status: user.previously_new_record? ? :created : :ok
        else
          render json: { errors: user.errors.full_messages }, status: :unprocessable_entity
        end
      end

      private

      def sync_params
        params.permit(:id, :clerk_id, :email, :first_name, :last_name, :phone,
                      email_addresses: [:email_address],
                      phone_numbers: [:phone_number])
      end
    end
  end
end
