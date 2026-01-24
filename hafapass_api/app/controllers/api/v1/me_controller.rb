module Api
  module V1
    class MeController < ApplicationController
      def show
        render json: {
          id: current_user.id,
          clerk_id: current_user.clerk_id,
          email: current_user.email,
          first_name: current_user.first_name,
          last_name: current_user.last_name,
          phone: current_user.phone,
          role: current_user.role
        }
      end
    end
  end
end
