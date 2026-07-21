# frozen_string_literal: true

require "digest"

class PilotReadiness
  EVENT_FIELDS = %w[
    id organization_id organizer_profile_id venue_id title description short_description venue_name venue_address
    venue_city starts_at ends_at doors_open_at timezone max_capacity category age_restriction fee_policy
    buyer_fee_percent transfers_enabled show_attendees supported_locales localized_content cover_image_url slug
    recurrence_parent_id recurrence_rule recurrence_end_date
  ].freeze
  TICKET_TYPE_FIELDS = %w[
    id name description price_cents quantity_available max_per_order max_per_buyer door_allocation sales_start_at
    sales_end_at sort_order
  ].freeze
  PRICING_TIER_FIELDS = %w[id name price_cents tier_type starts_at ends_at quantity_limit position].freeze
  EVENT_SEAT_FIELDS = %w[id venue_seat_id ticket_type_id operational_status general_release_at].freeze
  EVENT_PRICE_ZONE_FIELDS = %w[id seating_price_zone_id ticket_type_id].freeze
  CATALOG_ITEM_FIELDS = %w[
    id name description kind price_cents minimum_price_cents maximum_price_cents inventory_quantity position active
  ].freeze
  REGISTRATION_QUESTION_FIELDS = %w[id prompt kind options required position active].freeze
  WAIVER_FIELDS = %w[id title version content_digest required active].freeze
  PROMO_CODE_FIELDS = %w[id code discount_type discount_value max_uses starts_at expires_at active].freeze
  VENUE_FIELDS = %w[id name slug address village accessibility_notes verified active].freeze

  def self.event_state_digest(event)
    Digest::SHA256.hexdigest(JSON.generate(canonicalize(snapshot(event))))
  end

  def self.application_revision
    ENV["GIT_SHA"].presence || "development"
  end

  def self.active_approval(event, at: Time.current, state_digest: nil)
    revoked_ids = event.pilot_readiness_reviews.revocations.select(:parent_review_id)
    state_digest ||= event_state_digest(event)
    event.pilot_readiness_reviews.approvals
      .where.not(id: revoked_ids)
      .where(event_state_digest: state_digest)
      .where("effective_at <= ? AND expires_at > ?", at, at)
      .order(created_at: :desc).first
  end

  def self.pending_submission(event)
    decided_ids = event.pilot_readiness_reviews.where(decision: [:approval, :rejection]).select(:parent_review_id)
    event.pilot_readiness_reviews.decision_submission.where.not(id: decided_ids).order(created_at: :desc).first
  end

  def self.latest_approval(event)
    event.pilot_readiness_reviews.approvals.order(created_at: :desc).first
  end

  def self.status(event)
    state_digest = event_state_digest(event)
    approval = active_approval(event, state_digest: state_digest)
    latest = latest_approval(event)
    {
      required: Rails.env.production?,
      approved: approval.present?,
      state_current: latest.present? && latest.event_state_digest == state_digest,
      pending_submission: pending_submission(event),
      latest_approval: latest,
      required_controls: PilotReadinessReview::CONTROL_KEYS,
      required_assignments: PilotReadinessReview::ASSIGNMENT_KEYS,
      event_state_digest: state_digest
    }
  end

  def self.list_summary(event)
    reviews = event.pilot_readiness_reviews.to_a
    decided_submission_ids = reviews.filter_map do |review|
      review.parent_review_id if review.decision_approval? || review.decision_rejection?
    end
    pending = reviews.select do |review|
      review.decision_submission? && review.expires_at > Time.current && !decided_submission_ids.include?(review.id)
    end.max_by(&:created_at)
    latest_approval = reviews.select(&:decision_approval?).max_by(&:created_at)
    {
      approval_recorded: latest_approval.present?,
      pending_submission: pending && { id: pending.id, created_at: pending.created_at }
    }
  end

  def self.snapshot(event)
    ticket_types = event.ticket_types.includes(:pricing_tiers).order(:id).map do |ticket_type|
      ticket_type.attributes.slice(*TICKET_TYPE_FIELDS).merge(
        "pricing_tiers" => ticket_type.pricing_tiers.order(:id).map { |tier| tier.attributes.slice(*PRICING_TIER_FIELDS) }
      )
    end
    seating = event.event_seating_configuration
    seating_snapshot = if seating
      {
        id: seating.id,
        venue_layout_id: seating.venue_layout_id,
        venue_layout_name: seating.venue_layout.name,
        venue_layout_version: seating.venue_layout.version,
        venue_layout_renderer: seating.venue_layout.renderer,
        venue_layout_status: seating.venue_layout.status,
        venue_layout_provider_chart_key: seating.venue_layout.provider_chart_key,
        status: seating.status,
        price_zones: seating.event_price_zones.includes(:seating_price_zone).order(:id).map do |mapping|
          zone = mapping.seating_price_zone
          mapping.attributes.slice(*EVENT_PRICE_ZONE_FIELDS).merge(
            "zone_code" => zone.code,
            "zone_name" => zone.name,
            "zone_color" => zone.color,
            "zone_position" => zone.position
          )
        end,
        seats: seating.event_seats.includes(venue_seat: [:seating_price_zone, { seating_row: :seating_section }])
          .order(:id).map do |seat|
            venue_seat = seat.venue_seat
            row = venue_seat.seating_row
            section = row.seating_section
            zone = venue_seat.seating_price_zone
            seat.attributes.slice(*EVENT_SEAT_FIELDS).merge(
              "label" => venue_seat.label,
              "position" => venue_seat.position,
              "active" => venue_seat.active,
              "row" => row.label,
              "row_position" => row.position,
              "section" => section.name,
              "section_code" => section.code,
              "section_position" => section.position,
              "accessibility_kind" => venue_seat.accessibility_kind,
              "companion_group" => venue_seat.companion_group,
              "obstructed_view" => venue_seat.obstructed_view,
              "view_note" => venue_seat.view_note,
              "x" => venue_seat.x,
              "y" => venue_seat.y,
              "zone_id" => venue_seat.seating_price_zone_id,
              "zone_code" => zone.code,
              "zone_name" => zone.name,
              "zone_color" => zone.color
            )
          end
      }
    end
    organizer = event.organizer_profile
    connected_accounts = event.organization.connected_accounts.order(:id).map do |account|
      {
        id: account.id,
        provider: account.provider,
        status: account.status,
        payouts_enabled: account.payouts_enabled,
        readiness_state_digest: account.readiness_state_digest
      }
    end

    {
      application_revision: application_revision,
      event: event.attributes.slice(*EVENT_FIELDS),
      venue: event.venue&.attributes&.slice(*VENUE_FIELDS),
      organizer: {
        id: organizer.id,
        verification_status: organizer.verification_status,
        policy_version: organizer.policy_version,
        policy_digest: organizer.policy_digest,
        policy_accepted_at: organizer.policy_accepted_at
      },
      organization: { id: event.organization_id, status: event.organization.status },
      connected_accounts: connected_accounts,
      policy_registry_digest: PolicyRegistry.registry_digest,
      ticket_types: ticket_types,
      catalog_items: event.catalog_items.order(:id).map { |item| item.attributes.slice(*CATALOG_ITEM_FIELDS) },
      registration_questions: event.registration_questions.order(:id).map do |question|
        question.attributes.slice(*REGISTRATION_QUESTION_FIELDS)
      end,
      waivers: event.event_waivers.order(:id).map { |waiver| waiver.attributes.slice(*WAIVER_FIELDS) },
      promo_codes: event.promo_codes.order(:id).map { |code| code.attributes.slice(*PROMO_CODE_FIELDS) },
      seating: seating_snapshot
    }
  end
  private_class_method :snapshot

  def self.canonicalize(value)
    case value
    when Hash
      value.stringify_keys.sort.to_h.transform_values { |item| canonicalize(item) }
    when Array
      value.map { |item| canonicalize(item) }
    when Time, ActiveSupport::TimeWithZone, DateTime
      value.iso8601(6)
    when Date
      value.iso8601
    when BigDecimal
      value.to_s("F")
    else
      value
    end
  end
  private_class_method :canonicalize
end
