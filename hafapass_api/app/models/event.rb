class Event < ApplicationRecord
  has_many :message_deliveries, dependent: :restrict_with_error
  has_many :support_notes, dependent: :restrict_with_error
  belongs_to :organizer_profile
  belongs_to :organization
  belongs_to :venue, optional: true
  belongs_to :recurrence_parent, class_name: "Event", optional: true
  has_many :recurrence_children, class_name: "Event", foreign_key: "recurrence_parent_id", dependent: :nullify
  has_many :ticket_types, dependent: :destroy
  has_many :orders, dependent: :restrict_with_error
  has_many :tickets, dependent: :restrict_with_error
  has_many :inventory_holds, dependent: :restrict_with_error
  has_many :promo_codes, dependent: :destroy
  has_many :guest_list_entries, dependent: :destroy
  has_many :waitlist_entries, dependent: :destroy
  has_many :event_state_changes, dependent: :restrict_with_error
  has_many :event_changes, dependent: :restrict_with_error
  has_many :event_staff_assignments, dependent: :restrict_with_error
  has_many :settlements, dependent: :restrict_with_error
  has_many :payouts, dependent: :restrict_with_error
  has_many :balance_adjustments, dependent: :restrict_with_error
  has_many :scanner_devices, dependent: :restrict_with_error
  has_many :admission_manifests, dependent: :restrict_with_error
  has_many :admission_actions, dependent: :restrict_with_error
  has_many :card_present_payment_attempts, dependent: :restrict_with_error
  has_many :ticket_transfers, through: :tickets
  has_many :waitlist_offers, dependent: :restrict_with_error
  has_many :catalog_items, dependent: :restrict_with_error
  has_many :registration_questions, dependent: :restrict_with_error
  has_many :event_waivers, dependent: :restrict_with_error
  has_many :promoters, dependent: :restrict_with_error
  has_many :communication_campaigns, dependent: :restrict_with_error
  has_many :marketplace_collection_events, dependent: :restrict_with_error
  has_many :marketplace_collections, through: :marketplace_collection_events
  has_many :event_favorites, dependent: :destroy
  has_many :event_reminders, dependent: :destroy
  has_many :distribution_links, dependent: :restrict_with_error
  has_many :marketplace_funnel_events, dependent: :restrict_with_error
  has_many :event_referrals, dependent: :restrict_with_error
  has_one :event_seating_configuration, dependent: :restrict_with_error
  has_many :event_seats, through: :event_seating_configuration
  has_many :seat_audit_events, dependent: :restrict_with_error

  RECURRENCE_RULES = %w[weekly biweekly monthly].freeze
  CATEGORY_LABELS = {
    "nightlife" => "Nightlife",
    "concert" => "Music & Concerts",
    "festival" => "Festivals & Culture",
    "dining" => "Food & Drink",
    "sports" => "Sports & Fitness",
    "workshop" => "Classes & Workshops",
    "fundraiser" => "Fundraisers & Nonprofits",
    "family" => "Family",
    "business" => "Business & Networking",
    "other" => "Other"
  }.freeze
  validates :recurrence_rule, inclusion: { in: RECURRENCE_RULES }, allow_nil: true

  enum :status, { draft: 0, published: 1, cancelled: 2, completed: 3, postponed: 4, archived: 5 }
  enum :category, {
    nightlife: 0, concert: 1, festival: 2, dining: 3, sports: 4, other: 5,
    workshop: 6, fundraiser: 7, family: 8, business: 9
  }
  enum :age_restriction, { all_ages: 0, eighteen_plus: 1, twenty_one_plus: 2 }
  enum :fee_policy, { buyer_pays: 0, organizer_absorbs: 1, split_fees: 2 }

  validates :title, presence: true
  validates :slug, presence: true, uniqueness: true
  validates :max_capacity, numericality: { only_integer: true, greater_than: 0 }, allow_nil: true
  validates :buyer_fee_percent, numericality: { only_integer: true, in: 0..100 }
  validate :capacity_covers_committed_inventory
  validate :fee_policy_matches_percent
  validate :supported_locales_are_known
  validate :localized_content_is_valid
  validate :valid_iana_timezone
  validate :chronological_event_times

  before_validation :generate_slug, if: -> { slug.blank? || title_changed? }
  before_validation :copy_venue_details, if: -> { venue_id_changed? && venue.present? }

  scope :published, -> { where(status: :published) }
  scope :upcoming, -> { where("starts_at > ?", Time.current) }
  scope :past, -> { where("starts_at <= ?", Time.current) }
  scope :featured, -> { where(is_featured: true) }
  scope :publicly_visible, -> { where(status: [:published, :completed]) }
  scope :discoverable, ->(at = Time.current) {
    published
      .where("COALESCE(events.ends_at, events.starts_at) > ?", at)
      .where(sales_suspended_at: nil)
      .joins(:ticket_types)
      .where("ticket_types.sales_start_at IS NULL OR ticket_types.sales_start_at <= ?", at)
      .where("ticket_types.sales_end_at IS NULL OR ticket_types.sales_end_at > ?", at)
      .where(<<~SQL.squish, at, at, at)
        ticket_types.quantity_available - ticket_types.quantity_sold - COALESCE((
          SELECT SUM(inventory_holds.quantity)
          FROM inventory_holds
          WHERE inventory_holds.ticket_type_id = ticket_types.id
            AND inventory_holds.status = 0
            AND inventory_holds.expires_at > ?
        ), 0) - COALESCE((
          SELECT SUM(waitlist_offers.quantity)
          FROM waitlist_offers
          WHERE waitlist_offers.ticket_type_id = ticket_types.id
            AND waitlist_offers.status = 0
            AND waitlist_offers.expires_at > ?
        ), 0) - COALESCE((
          SELECT COUNT(*)
          FROM seat_holds
          INNER JOIN seat_hold_sessions ON seat_hold_sessions.id = seat_holds.seat_hold_session_id
          INNER JOIN event_seats ON event_seats.id = seat_holds.event_seat_id
          WHERE event_seats.ticket_type_id = ticket_types.id
            AND seat_holds.status = 0
            AND seat_hold_sessions.status = 0
            AND seat_hold_sessions.expires_at > ?
        ), 0) > 0
      SQL
      .where(<<~SQL.squish, at, at, at)
        events.max_capacity IS NULL OR events.max_capacity - COALESCE((
          SELECT SUM(all_ticket_types.quantity_sold)
          FROM ticket_types all_ticket_types
          WHERE all_ticket_types.event_id = events.id
        ), 0) - COALESCE((
          SELECT SUM(event_holds.quantity)
          FROM inventory_holds event_holds
          WHERE event_holds.event_id = events.id
            AND event_holds.status = 0
            AND event_holds.expires_at > ?
        ), 0) - COALESCE((
          SELECT SUM(event_offers.quantity)
          FROM waitlist_offers event_offers
          WHERE event_offers.event_id = events.id
            AND event_offers.status = 0
            AND event_offers.expires_at > ?
        ), 0) - COALESCE((
          SELECT COUNT(*)
          FROM seat_holds capacity_seat_holds
          INNER JOIN seat_hold_sessions capacity_sessions
            ON capacity_sessions.id = capacity_seat_holds.seat_hold_session_id
          INNER JOIN event_seats capacity_event_seats
            ON capacity_event_seats.id = capacity_seat_holds.event_seat_id
          INNER JOIN event_seating_configurations capacity_configurations
            ON capacity_configurations.id = capacity_event_seats.event_seating_configuration_id
          WHERE capacity_configurations.event_id = events.id
            AND capacity_seat_holds.status = 0
            AND capacity_sessions.status = 0
            AND capacity_sessions.expires_at > ?
        ), 0) > 0
      SQL
      .distinct
  }

  def category_label
    CATEGORY_LABELS.fetch(category)
  end

  def sales_open?(at: Time.current)
    published? && sales_suspended_at.nil? && (ends_at || starts_at).present? && (ends_at || starts_at) > at
  end

  def assigned_seating?
    event_seating_configuration&.status_active? || false
  end

  def content_for(locale)
    code = locale.to_s.split(/[-_]/).first
    translation = supported_locales.include?(code) ? localized_content.fetch(code, {}) : {}
    {
      title: translation["title"].presence || title,
      description: translation["description"].presence || description,
      short_description: translation["short_description"].presence || short_description
    }
  end

  def has_available_inventory?(at: Time.current)
    return false unless sales_open?(at: at)
    return false unless remaining_capacity(at: at).positive?

    ticket_types.any? { |ticket_type| ticket_type.on_sale?(at: at) && ticket_type.available_quantity.positive? }
  end

  def remaining_capacity(at: Time.current)
    return Float::INFINITY if max_capacity.blank?

    sold = ticket_types.sum(&:quantity_sold)
    held = inventory_holds.active.where("expires_at > ?", at).sum(:quantity) +
      waitlist_offers.holding_inventory(at).sum(:quantity) + active_seat_holds_count(at: at)
    [max_capacity - sold - held, 0].max
  end

  def publish_checklist(at: Time.current)
    paid_event = ticket_types.any? do |ticket_type|
      ticket_type.price_cents.positive? || ticket_type.pricing_tiers.any? { |tier| tier.price_cents.positive? }
    end
    configured_inventory = ticket_types.sum(&:quantity_available)
    checks = [
      checklist_item("organizer_verified", "Organizer identity verified", organizer_profile.verification_status_verified?),
      checklist_item("policy_accepted", "Organizer policy accepted", organizer_profile.policy_accepted?),
      checklist_item("title", "Event title added", title.present?),
      checklist_item("description", "Event description added", description.present?),
      checklist_item("venue", "Venue name and address added", venue_name.present? && venue_address.present? && venue_city.present?),
      checklist_item("schedule", "Future start and valid end time added", starts_at.present? && starts_at > at && ends_at.present? && ends_at > starts_at),
      checklist_item("timezone", "Valid IANA timezone selected", timezone_valid?),
      checklist_item("tickets", "At least one ticket type added", ticket_types.any?),
      checklist_item("capacity", "Event capacity added and ticket inventory fits", max_capacity.present? && configured_inventory.positive? && configured_inventory <= max_capacity),
      checklist_item("sales_window", "Ticket sales windows are valid", valid_ticket_sales_windows?(at: at)),
      checklist_item("payout", paid_event ? "Payout account ready for paid sales" : "No payout account needed for a free event",
        !paid_event || organization.payout_ready?)
    ]
    checks
  end

  def ready_to_publish?(at: Time.current)
    publish_checklist(at: at).all? { |item| item[:complete] }
  end

  # Check if tickets are available and notify next waitlisted people
  def notify_waitlist_if_available
    ticket_types.each do |tt|
      next unless tt.available_quantity > 0

      entries = waitlist_entries
        .where(status: :waiting)
        .where("ticket_type_id = ? OR ticket_type_id IS NULL", tt.id)
        .order(:position)
        .limit(tt.available_quantity)

      entries.each do |entry|
        entry.notify!
        EmailService.send_waitlist_notification_async(entry)
      end
    end
  end

  private

  def active_seat_holds_count(at: Time.current)
    return 0 unless event_seating_configuration

    SeatHold.status_active.joins(:seat_hold_session, :event_seat)
      .where(event_seats: { event_seating_configuration_id: event_seating_configuration.id })
      .where(seat_hold_sessions: { status: SeatHoldSession.statuses[:active] })
      .where("seat_hold_sessions.expires_at > ?", at).count
  end

  def copy_venue_details
    self.venue_name = venue.name
    self.venue_address = venue.address
    self.venue_city = venue.village
  end

  def fee_policy_matches_percent
    errors.add(:buyer_fee_percent, "must be 100 when the buyer pays fees") if buyer_pays? && buyer_fee_percent != 100
    errors.add(:buyer_fee_percent, "must be 0 when the organizer absorbs fees") if organizer_absorbs? && buyer_fee_percent != 0
    if split_fees? && !buyer_fee_percent.between?(1, 99)
      errors.add(:buyer_fee_percent, "must be between 1 and 99 for split fees")
    end
  end

  def supported_locales_are_known
    values = Array(supported_locales)
    errors.add(:supported_locales, "must include English") unless values.include?("en")
    errors.add(:supported_locales, "contains an unsupported locale") unless (values - %w[en ja ch]).empty?
  end

  def localized_content_is_valid
    unless localized_content.is_a?(Hash) && localized_content.keys.all? { |key| %w[ja ch].include?(key) }
      errors.add(:localized_content, "may only contain Japanese and CHamoru content")
      return
    end

    valid = localized_content.values.all? do |translation|
      translation.is_a?(Hash) && (translation.keys - %w[title description short_description]).empty? &&
        translation.values.all? { |value| value.is_a?(String) }
    end
    errors.add(:localized_content, "has an invalid translation shape") unless valid
  end

  def checklist_item(code, label, complete)
    { code: code, label: label, complete: !!complete }
  end

  def valid_ticket_sales_windows?(at: Time.current)
    return false if ticket_types.empty?

    ticket_types.all? do |ticket_type|
      starts_before_end = ticket_type.sales_start_at.blank? || ticket_type.sales_end_at.blank? ||
        ticket_type.sales_start_at < ticket_type.sales_end_at
      starts_before_event_end = ticket_type.sales_start_at.blank? || ends_at.blank? ||
        ticket_type.sales_start_at < ends_at
      ends_before_event = ticket_type.sales_end_at.blank? || ends_at.blank? || ticket_type.sales_end_at <= ends_at
      sale_still_possible = ticket_type.sales_end_at.blank? || ticket_type.sales_end_at > at
      starts_before_end && starts_before_event_end && ends_before_event && sale_still_possible
    end
  end

  def timezone_valid?
    TZInfo::Timezone.get(timezone.presence || "Pacific/Guam")
    true
  rescue TZInfo::InvalidTimezoneIdentifier
    false
  end

  def valid_iana_timezone
    errors.add(:timezone, "must be a valid IANA timezone") unless timezone_valid?
  end

  def chronological_event_times
    errors.add(:ends_at, "must be after the start time") if starts_at && ends_at && ends_at <= starts_at
    errors.add(:doors_open_at, "must be at or before the start time") if starts_at && doors_open_at && doors_open_at > starts_at
  end

  def capacity_covers_committed_inventory
    return if max_capacity.blank? || !persisted?

    committed = ticket_types.sum(:quantity_sold) + inventory_holds.current.sum(:quantity) +
      waitlist_offers.holding_inventory.sum(:quantity)
    errors.add(:max_capacity, "cannot be less than sold and actively held inventory") if max_capacity < committed
  end

  def generate_slug
    base_slug = title.to_s.parameterize
    self.slug = base_slug

    if Event.where(slug: self.slug).where.not(id: self.id).exists?
      self.slug = "#{base_slug}-#{SecureRandom.hex(3)}"
    end
  end
end
