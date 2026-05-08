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
    unless current_user
      render json: { error: "Unauthorized" }, status: :unauthorized
      return
    end
  end

  def current_user
    return @current_user if defined?(@current_user)

    clerk_id = @clerk_payload&.dig("sub")
    return nil if clerk_id.blank?

    @current_user = User.find_or_create_by!(clerk_id: clerk_id) do |user|
      user.email = clerk_email
      user.first_name = @clerk_payload["first_name"]
      user.last_name = @clerk_payload["last_name"]
      user.role = initial_role_for(user.email)
    end
  end

  def clerk_email
    @clerk_payload["email"] || @clerk_payload.dig("email_addresses", 0, "email_address")
  end

  def initial_role_for(email)
    return :admin if admin_email?(email)
    return :admin if first_user_admin_bootstrap_enabled?

    :attendee
  end

  def first_user_admin_bootstrap_enabled?
    return false unless User.count.zero?
    return true if Rails.env.development? || Rails.env.test?

    ActiveModel::Type::Boolean.new.cast(ENV.fetch("ENABLE_FIRST_USER_ADMIN_BOOTSTRAP", "false"))
  end

  def admin_email?(email)
    return false if email.blank?

    ENV.fetch("ADMIN_EMAILS", "")
      .split(",")
      .map { |value| value.strip.downcase }
      .include?(email.downcase)
  end

  def extract_bearer_token
    header = request.headers["Authorization"]
    return nil unless header&.start_with?("Bearer ")

    header.split(" ").last
  end
end
