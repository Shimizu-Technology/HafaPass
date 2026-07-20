class Event < ApplicationRecord
  belongs_to :organizer_profile
  belongs_to :organization
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

  validates :title, presence: true
  validates :slug, presence: true, uniqueness: true
  validates :max_capacity, numericality: { only_integer: true, greater_than: 0 }, allow_nil: true
  validate :capacity_covers_committed_inventory
  validate :valid_iana_timezone
  validate :chronological_event_times

  before_validation :generate_slug, if: -> { slug.blank? || title_changed? }

  scope :published, -> { where(status: :published) }
  scope :upcoming, -> { where("starts_at > ?", Time.current) }
  scope :past, -> { where("starts_at <= ?", Time.current) }
  scope :featured, -> { where(is_featured: true) }
  scope :publicly_visible, -> { where(status: [:published, :completed]) }
  scope :discoverable, ->(at = Time.current) {
    published
      .where("COALESCE(events.ends_at, events.starts_at) > ?", at)
      .joins(:ticket_types)
      .where("ticket_types.sales_start_at IS NULL OR ticket_types.sales_start_at <= ?", at)
      .where("ticket_types.sales_end_at IS NULL OR ticket_types.sales_end_at > ?", at)
      .where(<<~SQL.squish, at)
        ticket_types.quantity_available - ticket_types.quantity_sold - COALESCE((
          SELECT SUM(inventory_holds.quantity)
          FROM inventory_holds
          WHERE inventory_holds.ticket_type_id = ticket_types.id
            AND inventory_holds.status = 0
            AND inventory_holds.expires_at > ?
        ), 0) > 0
      SQL
      .where(<<~SQL.squish, at)
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
        ), 0) > 0
      SQL
      .distinct
  }

  def category_label
    CATEGORY_LABELS.fetch(category)
  end

  def sales_open?(at: Time.current)
    published? && (ends_at || starts_at).present? && (ends_at || starts_at) > at
  end

  def has_available_inventory?(at: Time.current)
    return false unless remaining_capacity(at: at).positive?

    ticket_types.any? { |ticket_type| ticket_type.on_sale?(at: at) && ticket_type.available_quantity.positive? }
  end

  def remaining_capacity(at: Time.current)
    return Float::INFINITY if max_capacity.blank?

    sold = ticket_types.sum(&:quantity_sold)
    held = inventory_holds.active.where("expires_at > ?", at).sum(:quantity)
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

    committed = ticket_types.sum(:quantity_sold) + inventory_holds.current.sum(:quantity)
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
