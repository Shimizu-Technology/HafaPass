class ApplicationController < ActionController::API
  rescue_from ClerkIdentity::LookupUnavailable do
    response.set_header("Retry-After", "5")
    render json: { error: "We could not verify your account yet. Please try again shortly.",
      code: "identity_verification_unavailable", retryable: true }, status: :service_unavailable
  end

  rescue_from ActionController::BadRequest do |error|
    render json: { error: error.message }, status: :bad_request
  end

  around_action :with_identity_verification_cache
  before_action :authenticate_user!
  before_action :set_observability_context
  before_action :enforce_launch_capability

  def append_info_to_payload(payload)
    super
    payload[:request_id] = request.request_id
    payload[:user_id] = @current_user.id if defined?(@current_user) && @current_user
  end

  private

  def with_identity_verification_cache(&block)
    ClerkIdentity.with_request_cache(&block)
  end

  def enforce_launch_capability
    feature = LaunchCapabilities.required_for(controller: controller_path, action: action_name, params: params)
    return unless feature && !LaunchCapabilities.enabled?(feature)

    render json: {
      error: "#{feature.to_s.humanize} is not available for this release.",
      code: "launch_capability_disabled"
    }, status: :unprocessable_entity
  end

  def set_observability_context
    Sentry.set_tags(request_id: request.request_id)
    return unless defined?(@current_user) && @current_user

    Sentry.set_user(id: @current_user.id)
  end

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
    return if current_user

    render json: { error: "Unauthorized" }, status: :unauthorized
  end

  def optional_authenticate_user!
    token = extract_bearer_token
    return if token.nil?

    payload = ClerkAuthenticator.verify(token)
    return if payload.nil?

    @clerk_payload = payload
    @current_user = current_user
  end

  def current_user
    return @current_user if defined?(@current_user)

    clerk_id = @clerk_payload&.dig("sub")
    return nil if clerk_id.blank?

    @current_user = User.find_or_create_by!(clerk_id: clerk_id) do |user|
      user.email = clerk_email
      user.first_name = @clerk_payload["first_name"]
      user.last_name = @clerk_payload["last_name"]
      user.role = initial_role_for(user)
    end
  end

  def clerk_email
    @clerk_payload["email"] || @clerk_payload.dig("email_addresses", 0, "email_address")
  end

  def initial_role_for(user)
    # Standard Clerk session tokens have no email claim. Resolve the server's
    # admin allowlist against verified provider addresses, not contact data.
    if ENV.fetch("ADMIN_EMAILS", "").present? &&
        ClerkIdentity.verified_email_addresses(user.clerk_id, require_available: true).any? { |email| admin_email?(email) }
      return :admin
    end
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
