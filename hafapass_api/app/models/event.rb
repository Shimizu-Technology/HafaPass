class Event < ApplicationRecord
  include OperationalAuditable

  # Source identity is transient, supplied by the clone operation before save.
  attr_accessor :audit_clone_source, :audit_sales_note
  after_update :audit_sales_suspension_change

  audits_operations :event,
    fields: %w[organization_id organizer_profile_id venue_id starts_at ends_at doors_open_at timezone
      category age_restriction max_capacity fee_policy buyer_fee_percent is_featured show_attendees
      transfers_enabled recurrence_parent_id recurrence_rule recurrence_end_date supported_locales],
    observe: %w[title slug description short_description cover_image_url venue_name venue_address venue_city
      localized_content]

  has_one :event_cancellation_refund_run, dependent: :restrict_with_error
  include PublicSlug
  include Translatable
  include EventPageCustomization

  CONTENT_FIELDS = %w[title short_description description].freeze
  translates(*CONTENT_FIELDS, context: "Public listing for an event sold on HåfaPass, a ticketing site in Guam. " \
    "Keep names of people, performers, venues, villages, organizations and brands as written, and keep CHamoru words as written.")

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
  validate :page_customization_is_valid, if: :will_save_change_to_page_customization?
  validate :cover_image_is_approved

  before_validation :assign_slug
  before_validation :clamp_page_focal_point, if: :will_save_change_to_page_customization?

  def cover_image_is_approved
    return unless new_record? || will_save_change_to_cover_image_url?
    return if cover_image_url.blank? || ApprovedImageUrl.valid?(cover_image_url, organization_id: organization_id)

    errors.add(:cover_image_url, ApprovedImageUrl::MESSAGE)
  end
  before_save :record_localized_content_sources, if: :will_save_change_to_localized_content?
  before_validation :copy_venue_details, if: -> { venue_id_changed? && venue.present? }
  after_update -> { Wallet::PassSync.event_changed(self) }, if: :wallet_visible_change?

  scope :published, -> { where(status: :published) }
  scope :upcoming, -> { where("starts_at > ?", Time.current) }
  scope :past, -> { where("starts_at <= ?", Time.current) }
  scope :featured, -> { where(is_featured: true) }
  scope :without_hidden_policy_hold, -> { where("events.policy_hold_scope IS DISTINCT FROM 'hidden'") }
  # Keep discovery and direct public URLs on the same production gate as sales.
  # Buyer-owned records deliberately do not use this scope.
  scope :with_public_organizer, -> {
    OrganizerProfile.verification_gate_enabled? ? where(organizer_profile_id: OrganizerProfile.verification_status_verified.select(:id)) : all
  }
  scope :publicly_visible, -> {
    where(status: [:published, :completed], live_money_proof_candidate: false)
      .without_hidden_policy_hold.with_public_organizer
  }
  scope :discoverable, ->(at = Time.current) {
    published
      .where(live_money_proof_candidate: false)
      .with_public_organizer
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
    !OrganizerProfile.verification_gate_enabled? || organizer_profile.verification_status_verified?
  end

  def publicly_visible?
    !live_money_proof_candidate? && %w[published completed].include?(status) &&
      policy_hold_scope != "hidden" && organizer_sales_verified?
  end

  def private_preview_eligible?
    published? && !organizer_profile.verification_status_suspended? &&
      policy_hold_scope != "hidden" && !live_money_proof_candidate?
  end

  def preview_token
    token = Rails.application.message_verifier("event-preview").generate([id, preview_token_version])
    digest = Digest::SHA256.hexdigest(token)
    update_column(:preview_token_digest, digest) if preview_token_digest != digest
    token
  end

  def valid_preview_token?(token)
    return false if token.blank? || preview_token_digest.blank?

    digest = Digest::SHA256.hexdigest(token.to_s)
    return false unless ActiveSupport::SecurityUtils.secure_compare(preview_token_digest, digest)

    Rails.application.message_verifier("event-preview").verified(token) == [id, preview_token_version]
  end

  def rotate_preview_token!
    with_lock do
      update_columns(preview_token_version: preview_token_version + 1, preview_token_digest: nil)
      preview_token
    end
  end

  def paid_event?
    ticket_types.any? do |ticket_type|
      ticket_type.price_cents.positive? || ticket_type.pricing_tiers.any? { |tier| tier.price_cents.positive? }
    end
  end

  # Why a published event is not selling, in organizer language. nil when the
  # event can sell. Checked in the order buyers and organizers would fix them.
  # Platform facts read once per request when many events are serialized.
  def self.sales_context
    { policy_approved: !Rails.env.production? || PolicyRegistry.production_approved?,
      stripe_enabled: SiteSetting.instance.stripe_enabled?, payout_ready: {} }
  end

  def sales_blocker(at: Time.current, context: nil)
    return :not_published unless published?
    unless organizer_sales_verified?
      return :organizer_paused if organizer_profile.verification_status_suspended?
      return :organizer_verification_requested if organizer_profile.verification_status_pending?

      return :organizer_not_verified
    end
    return :event_paused if policy_hold?
    return :sales_paused if sales_suspended_at.present?
    return :sales_closed if (ends_at || starts_at).blank? || (ends_at || starts_at) <= at

    context ||= self.class.sales_context
    return :platform_setup unless context[:policy_approved]
    return nil unless paid_event?
    return :payments_off if Rails.env.production? && !context[:stripe_enabled]

    payout_ready = context[:payout_ready].fetch(organization_id) do
      context[:payout_ready][organization_id] = organization.payout_ready?
    end
    return :payout_details_missing unless payout_ready

    nil
  end

  SALES_STATUS_MESSAGES = {
    not_published: "Not on sale: the event is not published.",
    event_paused: "Visible but not on sale: sales paused by HåfaPass.",
    sales_closed: "Not on sale: sales for this event have ended.",
    organizer_not_verified: "Private preview only: request organizer verification to go public and start selling.",
    organizer_verification_requested: "Private preview only: HåfaPass is reviewing your organizer account.",
    organizer_paused: "Hidden from public pages: HåfaPass suspended your organizer account and paused sales.",
    platform_setup: "Visible but not on sale yet: HåfaPass is finishing platform setup.",
    payments_off: "Visible but not on sale yet: HåfaPass has not turned on payments.",
    payout_details_missing: "Visible but not on sale yet: add your payout details in Settings → Payouts for paid tickets."
  }.freeze

  GATE_I_SUSPENSION_PREFIX = "[GATE I] "

  def sales_status(at: Time.current, context: nil)
    reason = sales_blocker(at: at, context: context)
    { on_sale: reason.nil?, reason: reason&.to_s, message: sales_status_message(reason) }
  end

  # Gate I pauses are placed by HåfaPass; seating pauses by the organizer.
  def sales_status_message(reason)
    return "On sale." unless reason
    return SALES_STATUS_MESSAGES.fetch(reason) unless reason == :sales_paused

    text = sales_suspension_reason.to_s
    by_hafapass = text.start_with?(GATE_I_SUSPENSION_PREFIX)
    detail = text.delete_prefix(GATE_I_SUSPENSION_PREFIX).strip.presence
    [by_hafapass ? "Sales paused by HåfaPass" : "Sales paused", detail].compact.join(": ") + "."
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

  RETRANSLATE_REFUSALS = {
    unavailable: ["Automatic translation is not available right now. Buyers see your English text.", :unprocessable_entity],
    not_public: ["Automatic translation starts when the event is published.", :unprocessable_entity],
    recently_requested: ["A translation was requested in the last few minutes. Try again shortly.", :too_many_requests]
  }.freeze

  # Queues a full machine re-translation of the event and its ticket types.
  # Returns :queued or the reason it was refused (see Translatable#retranslate!).
  def self.retranslate_with_ticket_types(event)
    outcome = event.retranslate!
    event.ticket_types.find_each { |ticket_type| ticket_type.queue_translation!(nil, force: true) } if outcome == :queued
    outcome
  end

  # Only text buyers can already see is sent for machine translation.
  def machine_translation_eligible?(status_value = status, hold = policy_hold_scope, proof = live_money_proof_candidate)
    %w[published completed].include?(status_value.to_s) && !proof && hold != "hidden"
  end

  # Public text in a buyer's language: the organizer's own translation first,
  # then a current machine translation, then the English original. Languages
  # not enabled on the server (HAFAPASS_ENABLED_LOCALES) read as English.
  def content_for(locale)
    code = AppLocale.normalize(locale)
    code = AppLocale::DEFAULT unless code && AppLocale.enabled?(code)
    provided = supported_locales.include?(code) ? localized_content.fetch(code, {}) : {}
    machine_translated = false
    content = CONTENT_FIELDS.to_h do |field|
      next [field.to_sym, provided[field]] if provided[field].present?

      value, machine = translated_value(field, code)
      machine_translated ||= machine
      [field.to_sym, value]
    end
    content.merge(locale: code, machine_translated: machine_translated)
  end

  # { locale => [fields] } of organizer wording written for English that has
  # since changed, so the organizer can review it.
  def stale_localized_content
    localized_content.each_with_object({}) do |(locale, fields), stale|
      changed = fields.keys.select do |field|
        source = localized_content_sources.dig(locale, field)
        source.present? && source != Translatable.digest(self[field])
      end
      stale[locale] = changed if changed.any?
    end
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
  def publish_checklist(at: Time.current, organizer_agreement: nil)
    paid_event = paid_event?
    configured_inventory = ticket_types.sum(&:quantity_available)
    [
      checklist_item("launch_scope", "Event features supported for this release", LaunchCapabilities.event_supported?(self)),
      # In production an unverified organizer may publish (to preview and
      # share); tickets go on sale once HåfaPass verifies them. Elsewhere
      # verification is still required to publish.
      checklist_item("organizer_verified", "Organizer identity verified", organizer_profile.verification_status_verified?,
        required_to_publish: !OrganizerProfile.verification_gate_enabled?),
      checklist_item("policy_accepted", "Organizer policy accepted",
        organizer_profile.policy_accepted?(current: organizer_agreement || PolicyRegistry.organizer_agreement)),
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
    publish_checklist(at: at).all? { |item| item[:complete] || !item[:required_to_publish] }
  end

  def live_money_proof_candidate_configured?
    types = ticket_types.to_a
    type = types.one? ? types.first : nil
    buyer_fee = Commerce::ServiceFee.for_event(self, type.price_cents).buyer_fee_cents if type
    live_money_proof_candidate? && title.start_with?("[LIVE MONEY TEST]") && max_capacity == 1 &&
      type.present? && type.price_cents.between?(1, 500) && type.quantity_available == 1 &&
      type.price_cents + buyer_fee <= LiveMoneyProofAuthorization::MAX_AMOUNT_CENTS && type.max_per_order == 1 &&
      type.max_per_buyer == 1 && type.pricing_tiers.empty? && catalog_items.none? && promo_codes.none? &&
      event_seating_configuration.nil?
  end

  # Check if tickets are available and notify next waitlisted people
  def notify_waitlist_if_available
    return unless WaitlistDelivery.address_ready?(self)
    ticket_types.each do |tt|
      next unless tt.available_quantity > 0

      entries = waitlist_entries
        .where(status: :waiting)
        .where("ticket_type_id = ? OR ticket_type_id IS NULL", tt.id)
        .order(:position)
        .limit(tt.available_quantity)

      entries.each do |entry|
        entry.notify_and_queue!
      rescue WaitlistDelivery::AddressMissing
        break
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

  def audit_sales_suspension_change
    return unless saved_change_to_sales_suspended_at?

    AuditLogger.record!(action: sales_suspended_at ? "event.sales_suspended" : "event.sales_resumed",
      auditable: self, event: self,
      before_data: { sales_suspended_at: sales_suspended_at_before_last_save,
        sales_suspension_reason: sales_suspension_reason_before_last_save },
      after_data: { sales_suspended_at: sales_suspended_at, sales_suspension_reason: sales_suspension_reason },
      metadata: { note: audit_sales_note }.compact)
  end

  def operational_audit_action(operation)
    if operation == :create
      return "event.recurrence_created" if recurrence_parent_id.present?
      return "event.cloned" if audit_clone_source
    end

    super
  end

  def operational_audit_metadata(operation)
    return { source_event_id: audit_clone_source.id } if operation == :create && audit_clone_source

    super
  end

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

  def translation_became_eligible?
    machine_translation_eligible? &&
      !machine_translation_eligible?(status_in_database, policy_hold_scope_in_database, live_money_proof_candidate_in_database)
  end

  # Ticket types were not sent while the event was private.
  def translation_cascade
    ticket_types.find_each { |ticket_type| ticket_type.queue_translation!(nil) }
  end

  # Remembers which English each piece of organizer wording was written for.
  def record_localized_content_sources
    before = localized_content_in_database || {}
    self.localized_content_sources = localized_content.to_h do |locale, fields|
      kept = localized_content_sources.fetch(locale, {})
      [locale, fields.to_h do |field, value|
        unchanged = before.dig(locale, field) == value && kept[field].present?
        [field, unchanged ? kept[field] : Translatable.digest(self[field])]
      end]
    end
  end

  def supported_locales_are_known
    values = Array(supported_locales)
    errors.add(:supported_locales, "must include English") unless values.include?("en")
    unless (values - [AppLocale::DEFAULT] - AppLocale::ORGANIZER_CONTENT_LOCALES).empty?
      errors.add(:supported_locales, "contains an unsupported locale")
    end
  end

  def localized_content_is_valid
    unless localized_content.is_a?(Hash) && (localized_content.keys - AppLocale::ORGANIZER_CONTENT_LOCALES).empty?
      errors.add(:localized_content, "may only contain supported languages")
      return
    end

    valid = localized_content.values.all? do |translation|
      translation.is_a?(Hash) && (translation.keys - CONTENT_FIELDS).empty? &&
        translation.values.all? { |value| value.is_a?(String) }
    end
    errors.add(:localized_content, "has an invalid translation shape") unless valid
  end

  def checklist_item(code, label, complete, required_to_publish: true)
    { code: code, label: label, complete: !!complete, required_to_publish: required_to_publish }
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
