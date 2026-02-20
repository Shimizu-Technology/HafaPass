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

        # Only update attributes that are actually present in the request
        # to avoid wiping existing data on partial syncs
        attrs = {}
        email = sync_params[:email] || sync_params.dig(:email_addresses, 0, :email_address)
        attrs[:email] = email if email.present?
        attrs[:first_name] = sync_params[:first_name] if sync_params.key?(:first_name) && sync_params[:first_name].present?
        attrs[:last_name] = sync_params[:last_name] if sync_params.key?(:last_name) && sync_params[:last_name].present?
        phone = sync_params[:phone] || sync_params.dig(:phone_numbers, 0, :phone_number)
        attrs[:phone] = phone if phone.present?

        user.assign_attributes(attrs)

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
