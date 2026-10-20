class Event < ApplicationRecord
  include PublicSlug

  has_many :message_deliveries, dependent: :restrict_with_error
  has_many :support_notes, dependent: :restrict_with_error
  belongs_to :organizer_profile
  belongs_to :organization
  belongs_to :venue, optional: true
  belongs_to :policy_hold_by_user, class_name: "User", optional: true
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
  has_many :pilot_readiness_reviews, dependent: :restrict_with_error
  has_many :pilot_validation_reviews, dependent: :restrict_with_error
  has_many :event_day_rehearsal_reviews, dependent: :restrict_with_error
  has_many :live_money_proof_authorizations, dependent: :restrict_with_error
  has_many :live_money_proof_reviews, foreign_key: :proof_event_id, dependent: :restrict_with_error,
    inverse_of: :proof_event
  has_many :live_pilot_reviews, dependent: :restrict_with_error
  has_many :live_pilot_runs, dependent: :restrict_with_error
  has_many :live_pilot_run_actions, dependent: :restrict_with_error
  has_many :live_pilot_incidents, dependent: :restrict_with_error
  has_many :live_pilot_metric_snapshots, dependent: :restrict_with_error
  has_many :pilot_closeout_reviews, dependent: :restrict_with_error
  # Only events that were once public keep retired links, and those events
  # cannot be deleted; a draft's rows (from a reclaimed link) go with it.
  has_many :slug_redirects, class_name: "EventSlugRedirect", dependent: :delete_all
  public_slug_redirects :slug_redirects

  RECURRENCE_RULES = %w[weekly biweekly monthly].freeze
  # A platform-admin policy hold: "sales" stops all sales but leaves the event
  # page up; "hidden" also removes it from public pages and discovery.
  POLICY_HOLD_SCOPES = %w[sales hidden].freeze
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
  validates :slug, presence: true
  validates :slug, uniqueness: { message: "is already used by another event" }, unless: :slug_chosen?
  validate :chosen_slug_is_available, if: :slug_chosen?
  validates :max_capacity, numericality: { only_integer: true, greater_than: 0, less_than_or_equal_to: 2_147_483_647 }, allow_nil: true
  validates :buyer_fee_percent, numericality: { only_integer: true, in: 0..100 }
  validate :capacity_covers_committed_inventory
  validate :fee_policy_matches_percent
  validate :supported_locales_are_known
  validate :localized_content_is_valid
  validate :valid_iana_timezone
  validate :chronological_event_times
  validate :live_money_candidate_flag_immutable_after_orders

  before_validation :assign_slug
  before_validation :copy_venue_details, if: -> { venue_id_changed? && venue.present? }
  after_update -> { Wallet::PassSync.event_changed(self) }, if: :wallet_visible_change?

  scope :published, -> { where(status: :published) }
  scope :upcoming, -> { where("starts_at > ?", Time.current) }
  scope :past, -> { where("starts_at <= ?", Time.current) }
  scope :featured, -> { where(is_featured: true) }
  scope :without_hidden_policy_hold, -> { where("events.policy_hold_scope IS DISTINCT FROM 'hidden'") }
  scope :publicly_visible, -> {
    where(status: [:published, :completed], live_money_proof_candidate: false).without_hidden_policy_hold
  }
  scope :discoverable, ->(at = Time.current) {
    published
      .where(live_money_proof_candidate: false)
      .where(policy_hold_at: nil)
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

  # Production's one sales gate: HåfaPass has verified the organizer (one
  # admin action; suspending verification pauses all of the organizer's sales).
  # It is not tied to deploys or event edits. Elsewhere nothing extra applies.
  def sales_open?(at: Time.current)
    published? && sales_suspended_at.nil? && policy_hold_at.nil? && (ends_at || starts_at).present? &&
      (ends_at || starts_at) > at && organizer_sales_verified?
  end

  def organizer_sales_verified?
    !Rails.env.production? || organizer_profile.verification_status_verified?
  end

  def paid_event?
    ticket_types.any? do |ticket_type|
      ticket_type.price_cents.positive? || ticket_type.pricing_tiers.any? { |tier| tier.price_cents.positive? }
    end
  end

  # Why a published event is not selling, in organizer language. nil when the
  # event can sell. Checked in the order buyers and organizers would fix them.
  def sales_blocker(at: Time.current)
    return :not_published unless published?
    return :event_paused if policy_hold?
    return :sales_closed if sales_suspended_at.present? || (ends_at || starts_at).blank? || (ends_at || starts_at) <= at

    unless organizer_sales_verified?
      return :organizer_paused if organizer_profile.verification_status_suspended?
      return :organizer_verification_requested if organizer_profile.verification_status_pending?

      return :organizer_not_verified
    end
    return :platform_setup if Rails.env.production? && !PolicyRegistry.production_approved?
    return nil unless paid_event?
    return :payments_off if Rails.env.production? && !SiteSetting.instance.stripe_enabled?
    return :payout_details_missing unless organization.payout_ready?

    nil
  end

  SALES_STATUS_MESSAGES = {
    not_published: "Not on sale: the event is not published.",
    event_paused: "Visible but not on sale: sales paused by HåfaPass.",
    sales_closed: "Not on sale: sales are closed or paused for this event.",
    organizer_not_verified: "Visible but not on sale yet: waiting for HåfaPass to verify your organization before tickets go on sale.",
    organizer_verification_requested: "Visible but not on sale yet: verification requested. HåfaPass will review it soon.",
    organizer_paused: "Visible but not on sale: HåfaPass paused sales for your organization.",
    platform_setup: "Visible but not on sale yet: HåfaPass is finishing platform setup.",
    payments_off: "Visible but not on sale yet: HåfaPass has not turned on payments.",
    payout_details_missing: "Visible but not on sale yet: add payout details (a check payee and mailing address) for paid tickets."
  }.freeze

  def sales_status(at: Time.current)
    reason = sales_blocker(at: at)
    { on_sale: reason.nil?, reason: reason&.to_s, message: reason ? SALES_STATUS_MESSAGES.fetch(reason) : "On sale." }
  end

  def policy_hold?
    policy_hold_at.present?
  end

  # Organizers see the scope, reason and time; only admins see who placed it.
  def policy_hold_summary(include_actor: false)
    return nil unless policy_hold?

    summary = { scope: policy_hold_scope, reason: policy_hold_reason, placed_at: policy_hold_at }
    include_actor ? summary.merge(placed_by: policy_hold_by_user&.email) : summary
  end

  # The stored setting only takes effect while the platform allows transfers.
  def transfers_available?
    transfers_enabled? && LaunchCapabilities.enabled?(:ticket_transfers)
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

  # The detailed launch-gate reviews (pilot readiness, validation, rehearsal,
  # live-money proof, bounded pilot) are optional records now; they never
  # block publishing or sales. Organizer verification is the one admin step.
  def publish_checklist(at: Time.current)
    paid_event = paid_event?
    configured_inventory = ticket_types.sum(&:quantity_available)
    [
      checklist_item("launch_scope", "Event features supported for this release", LaunchCapabilities.event_supported?(self)),
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
      checklist_item("live_money_candidate_scope", "Live-money proof event is hidden, single-ticket, and capped at $5",
        !live_money_proof_candidate? || live_money_proof_candidate_configured?),
      checklist_item("payout", paid_event ? "Payout details on file for paid sales" : "No payout details needed for a free event",
        !paid_event || organization.payout_ready?)
    ]
  end

  def ready_to_publish?(at: Time.current)
    publish_checklist(at: at).all? { |item| item[:complete] }
  end

  def live_money_proof_candidate_configured?
    types = ticket_types.to_a
    type = types.one? ? types.first : nil
    settings = SiteSetting.instance
    buyer_fee = if type
      platform_fee = (type.price_cents * (settings.service_fee_percent / 100.0)).round + settings.service_fee_flat_cents
      (platform_fee * buyer_fee_percent / 100.0).round
    end
    live_money_proof_candidate? && title.start_with?("[LIVE MONEY TEST]") && max_capacity == 1 &&
      type.present? && type.price_cents.between?(1, 500) && type.quantity_available == 1 &&
      type.price_cents + buyer_fee <= LiveMoneyProofAuthorization::MAX_AMOUNT_CENTS && type.max_per_order == 1 &&
      type.max_per_buyer == 1 && type.pricing_tiers.empty? && catalog_items.none? && promo_codes.none? &&
      event_seating_configuration.nil?
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
        entry.with_lock do
          next unless entry.waiting?

          entry.notify!
          EmailService.send_waitlist_notification_async(entry)
        end
      end
    end
  end

  # Published, postponed, cancelled and completed events were public at some
  # point. Archived events count when their history shows a publish.
  def ever_published?
    return true if published_at.present? || %w[published postponed cancelled completed].include?(status_in_database)
    return false if new_record?

    event_state_changes.exists?(to_status: "published")
  end

  def slug_follows_title?
    !custom_slug? && !ever_published?
  end

  private

  def active_seat_holds_count(at: Time.current)
    return 0 unless event_seating_configuration

    SeatHold.status_active.joins(:seat_hold_session, :event_seat)
      .where(event_seats: { event_seating_configuration_id: event_seating_configuration.id })
      .where(seat_hold_sessions: { status: SeatHoldSession.statuses[:active] })
      .where("seat_hold_sessions.expires_at > ?", at).count
  end

  def live_money_candidate_flag_immutable_after_orders
    return unless live_money_proof_candidate_changed? && persisted?

    if !draft?
      errors.add(:live_money_proof_candidate, "can only change while the event is a draft")
    elsif orders.exists?
      errors.add(:live_money_proof_candidate, "cannot change after the event has orders")
    end
  end

  def wallet_visible_change?
    %w[status title starts_at ends_at venue_name venue_address].any? { |attribute| saved_change_to_attribute?(attribute) }
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
      waitlist_offers.holding_inventory.sum(:quantity) + active_seat_holds_count(at: Time.current)
    errors.add(:max_capacity, "cannot be less than sold and actively held inventory") if max_capacity < committed
  end

  # Links are generated from the title. A draft's link follows title edits
  # until the organizer picks a link name; once an event has ever been public,
  # its link changes only when someone deliberately chooses a new one.
  def assign_slug
    @slug_chosen = slug_changed? && slug.present? && slug != @generated_slug
    if @slug_chosen
      self.slug = self.class.normalize_public_slug(slug)
      self.custom_slug = true
    elsif slug.blank? || (title_changed? && slug_follows_title? && @slug_generated_from != title)
      @slug_generated_from = title
      self.slug = @generated_slug = unique_generated_slug(title, fallback: "event")
    end
  end

  def slug_chosen?
    @slug_chosen == true
  end

  def generated_slug_source
    [title, "event"]
  end

  def chosen_slug_is_available
    problem = self.class.public_slug_problem(slug, record: self)
    errors.add(:slug, problem) if problem
  end

  def retain_previous_slug?
    ever_published?
  end
end
