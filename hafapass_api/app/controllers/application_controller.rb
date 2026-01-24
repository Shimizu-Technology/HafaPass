class ApplicationController < ActionController::API
  before_action :authenticate_user!

  private

  def authenticate_user!
    token = extract_bearer_token
    if token.nil?
      render json: { error: "Unauthorized" }, status: :unauthorized
      return
    end

    payload = ClerkAuthenticator.verify(token)
    if payload.nil?
      render json: { error: "Unauthorized" }, status: :unauthorized
      return
    end

    @clerk_payload = payload
    current_user # Ensure user is found or created
  end

  def current_user
    return @current_user if defined?(@current_user)

    clerk_id = @clerk_payload&.dig("sub")
    return nil if clerk_id.blank?

    @current_user = User.find_or_create_by!(clerk_id: clerk_id) do |user|
      user.email = @clerk_payload["email"] || @clerk_payload.dig("email_addresses", 0, "email_address")
      user.first_name = @clerk_payload["first_name"]
      user.last_name = @clerk_payload["last_name"]
      # First user created becomes admin
      user.role = User.count.zero? ? :admin : :attendee
    end
  end

  def extract_bearer_token
    header = request.headers["Authorization"]
    return nil unless header&.start_with?("Bearer ")

    header.split(" ").last
  end
end
