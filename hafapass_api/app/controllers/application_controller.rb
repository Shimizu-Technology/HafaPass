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

  # The visitor's language (see AppLocale): ?locale= first, then Accept-Language.
  def request_locale
    @request_locale ||= AppLocale.resolve(param: params[:locale], accept_language: request.headers["Accept-Language"])
  end

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

    @current_user = User.find_by(clerk_id: clerk_id) || create_user_from_clerk(clerk_id)
    # Accounts created before this lookup (or during a Clerk outage) refill
    # through the leased profile sync, which bounds provider calls to one per
    # account every few minutes instead of one per request.
    return @current_user if @current_user.email.present? || @current_user.previously_new_record?

    @current_user = ClerkProfileSync.call(@current_user)
  end

  # The provider lookup runs before the insert so no transaction or row lock
  # waits on Clerk. Parallel first requests race on the unique clerk_id index;
  # the loser re-reads the winner's row instead of failing.
  def create_user_from_clerk(clerk_id)
    profile = new_account_profile(clerk_id) if clerk_email.blank?
    user = User.new(
      clerk_id: clerk_id,
      email: clerk_email.presence || profile&.fetch(:email, nil),
      first_name: @clerk_payload["first_name"].presence || profile&.fetch(:first_name, nil),
      last_name: @clerk_payload["last_name"].presence || profile&.fetch(:last_name, nil)
    )
    user.role = initial_role_for(user)
    User.transaction(requires_new: true) { user.save! }
    user
  rescue ActiveRecord::RecordNotUnique, ActiveRecord::RecordInvalid
    User.find_by(clerk_id: clerk_id) || raise
  end

  def clerk_email
    @clerk_payload["email"] || @clerk_payload.dig("email_addresses", 0, "email_address")
  end

  # Standard Clerk session tokens carry no email claim, so a new account would
  # otherwise wait for a later profile sync to learn its contact address.
  # ClerkIdentity reuses a successful lookup for initial_role_for's
  # verified-address check; a timed-out short lookup is retried there at the
  # full timeout. A failure still creates the account; the email stays blank
  # until the next sync.
  def new_account_profile(clerk_id)
    profile = ClerkIdentity.profile(clerk_id, timeout: ClerkIdentity::SIGN_IN_TIMEOUT)
    Rails.logger.info("Clerk profile unavailable for a new account; email will sync later") unless profile&.dig(:email)
    profile
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
