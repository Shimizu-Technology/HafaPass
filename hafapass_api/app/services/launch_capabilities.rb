# frozen_string_literal: true

# HAFAPASS_LAUNCH_SCOPE picks a preset (general_admission = every capability
# off, full = every capability on). HAFAPASS_LAUNCH_CAPABILITIES is a comma list
# of capabilities enabled on top of that preset, e.g. "ticket_transfers".
class LaunchCapabilities
  class ConfigurationError < StandardError; end

  FEATURES = %w[assigned_seating recurring_events advanced_sales_tools ticket_transfers door_card].freeze
  SCOPES = %w[general_admission full].freeze

  def self.scope
    ENV["HAFAPASS_LAUNCH_SCOPE"].presence || ((Rails.env.production? || Rails.env.staging?) ? "general_admission" : "full")
  end

  def self.requested_capabilities
    ENV["HAFAPASS_LAUNCH_CAPABILITIES"].to_s.split(",").map { |name| name.strip.downcase }.reject(&:blank?).uniq
  end

  def self.unknown_capabilities
    requested_capabilities - FEATURES
  end

  # Extra capabilities only count when every requested name is known, so a typo
  # never half-applies a list.
  def self.additional_capabilities
    unknown_capabilities.empty? ? requested_capabilities : []
  end

  def self.configured?
    SCOPES.include?(scope) && unknown_capabilities.empty?
  end

  # Deployed environments refuse to boot with a misspelled scope or capability.
  def self.validate!
    raise ConfigurationError, "HAFAPASS_LAUNCH_SCOPE must be one of: #{SCOPES.join(', ')}" unless SCOPES.include?(scope)
    return if unknown_capabilities.empty?

    raise ConfigurationError, "HAFAPASS_LAUNCH_CAPABILITIES has unknown capabilities: #{unknown_capabilities.join(', ')} " \
      "(known: #{FEATURES.join(', ')})"
  end

  def self.enabled?(feature)
    feature = feature.to_s
    return false unless FEATURES.include?(feature) && SCOPES.include?(scope)

    scope == "full" || additional_capabilities.include?(feature)
  end

  def self.public_configuration
    FEATURES.index_with { |feature| enabled?(feature) }
  end

  def self.event_supported?(event)
    return false if !enabled?(:assigned_seating) && event.event_seating_configuration.present?
    return false if !enabled?(:recurring_events) && (event.recurrence_rule.present? || event.recurrence_parent_id.present?)
    return true if enabled?(:advanced_sales_tools)

    !event.catalog_items.where(active: true).exists? &&
      !event.registration_questions.where(active: true).exists? && !event.event_waivers.where(active: true).exists?
  end

  def self.required_for(controller:, action:, params:)
    case controller
    when "api/v1/event_seating"
      :assigned_seating unless action == "destroy_hold"
    when "api/v1/organizer/event_seating", "api/v1/organizer/venue_layouts"
      :assigned_seating unless %w[index show].include?(action)
    when "api/v1/organizer/events"
      return :ticket_transfers if %w[create update].include?(action) &&
        ActiveModel::Type::Boolean.new.cast(params[:transfers_enabled])

      :recurring_events if action == "generate_recurrences" ||
        (%w[create update].include?(action) && params[:recurrence_rule].present?)
    when "api/v1/organizer/catalog_items", "api/v1/organizer/registration_questions",
      "api/v1/organizer/event_waivers", "api/v1/organizer/promoters", "api/v1/organizer/communication_campaigns"
      :advanced_sales_tools unless %w[index show].include?(action)
    when "api/v1/ticket_transfers"
      :ticket_transfers unless action == "destroy"
    when "api/v1/me/ticket_transfers"
      :ticket_transfers unless action == "destroy"
    when "api/v1/orders"
      return :ticket_transfers if action == "create_transfer"
      return :assigned_seating if action == "exchange_seat"
      return unless action == "create"

      return :assigned_seating if params[:seat_hold_token].present?
      :advanced_sales_tools if params[:catalog_items].present? || params[:registration_answers].present? ||
        params[:waiver_acceptances].present?
    when "api/v1/organizer/box_office"
      :door_card if action == "create" && params[:payment_method] == "door_card"
    end
  end
end
