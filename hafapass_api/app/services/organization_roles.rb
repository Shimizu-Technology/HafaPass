# frozen_string_literal: true

# Plain-language names and one-line descriptions for every role a person can
# be given. The frontend keeps the same copy in src/utils/roles.js.
module OrganizationRoles
  LABELS = {
    "owner" => "Owner",
    "manager" => "Manager",
    "finance" => "Finance",
    "marketer" => "Marketer",
    "box_office" => "Box office",
    "scanner" => "Door scanner"
  }.freeze

  DESCRIPTIONS = {
    "owner" => "manages the team, payouts and all events",
    "manager" => "runs events day to day and sees sales; can't cancel events or move money",
    "finance" => "sales reports, refunds and payouts, including buyer contact details in refunds and finance exports",
    "marketer" => "event pages, promo codes and messages",
    "box_office" => "door sales and fixes for assigned events, plus scanning",
    "scanner" => "scans tickets at assigned events only"
  }.freeze

  PLATFORM_LABELS = { "admin" => "Admin", "support" => "Support" }.freeze
  PLATFORM_DESCRIPTIONS = {
    "admin" => "runs HåfaPass",
    "support" => "helps buyers with orders and tickets, no money or settings"
  }.freeze

  # Roles that can be invited straight onto one event from its Team page.
  EVENT_ASSIGNMENT_DESCRIPTION = "Event assignments add access for this event only."
  EVENT_STAFF_INVITE_ROLES = %w[box_office scanner].freeze

  module_function

  def label(role) = LABELS.fetch(role.to_s, role.to_s.humanize)
  def description(role) = DESCRIPTIONS.fetch(role.to_s, "")
  def platform_label(role) = PLATFORM_LABELS.fetch(role.to_s, role.to_s.humanize)
  def platform_description(role) = PLATFORM_DESCRIPTIONS.fetch(role.to_s, "")
end
