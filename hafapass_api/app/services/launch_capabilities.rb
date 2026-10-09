# frozen_string_literal: true

class LaunchCapabilities
  FEATURES = %w[assigned_seating recurring_events advanced_sales_tools ticket_transfers door_card].freeze
  SCOPES = %w[general_admission full].freeze

  def self.scope
    ENV["HAFAPASS_LAUNCH_SCOPE"].presence || ((Rails.env.production? || Rails.env.staging?) ? "general_admission" : "full")
  end

  def self.configured?
    SCOPES.include?(scope)
  end

  def self.enabled?(feature)
    FEATURES.include?(feature.to_s) && scope == "full"
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
