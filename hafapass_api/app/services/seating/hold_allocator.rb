# frozen_string_literal: true

module Seating
  class HoldAllocator
    HOLD_DURATION = 10.minutes

    class HoldError < StandardError; end
    Result = Data.define(:session, :token)

    def self.call(**)
      new(**).call
    end

    def initialize(event:, event_seat_ids:, accessibility_attested:, user: nil, source: "online", at: Time.current)
      @event = event
      @event_seat_ids = Array(event_seat_ids).map(&:to_i).uniq.sort
      @accessibility_attested = ActiveModel::Type::Boolean.new.cast(accessibility_attested) || false
      @user = user
      @source = source
      @at = at
    end

    def call
      raise HoldError, "Select at least one seat" if event_seat_ids.empty?
      raise HoldError, "This event is not currently on sale" unless event.sales_open?(at: at)

      result = nil
      SeatHoldSession.transaction do
        configuration = event.event_seating_configuration&.lock!
        raise HoldError, "Assigned seating is not active for this event" unless configuration&.status_active?

        seats = configuration.event_seats.where(id: event_seat_ids)
          .includes(venue_seat: { seating_row: :seating_section }).order(:id).lock.to_a
        raise HoldError, "One or more seats are not part of this event" unless seats.length == event_seat_ids.length

        SessionLifecycle.expire_stale!(event_seat_ids: event_seat_ids, at: at)
        unavailable = seats.reject { |seat| selectable_after_lock?(seat) }
        raise HoldError, "One or more selected seats are no longer available" if unavailable.any?

        validate_accessibility!(seats)
        token, digest = Credential.issue
        session = configuration.seat_hold_sessions.create!(
          user: user,
          token_digest: digest,
          source: source,
          accessibility_attested: accessibility_attested,
          expires_at: at + HOLD_DURATION
        )
        seats.each do |seat|
          tier = seat.ticket_type.active_pricing_tier(at: at)
          session.seat_holds.create!(
            event_seat: seat,
            pricing_tier: tier,
            unit_price_cents: tier&.price_cents || seat.ticket_type.price_cents
          )
        end
        Audit.record!(event: event, action: "seat_hold.created", session: session, actor: user,
          metadata: { source: source, event_seat_ids: event_seat_ids })
        result = Result.new(session: session, token: token)
      end
      result
    rescue ActiveRecord::RecordNotUnique
      raise HoldError, "One or more selected seats are no longer available"
    end

    private

    attr_reader :event, :event_seat_ids, :accessibility_attested, :user, :source, :at

    def selectable_after_lock?(seat)
      seat.operational_status_available? &&
        !Ticket.where(event_seat: seat, status: [:issued, :checked_in, :transferred]).exists? &&
        !SeatHold.where(event_seat: seat, status: [:active, :claimed]).joins(:seat_hold_session)
          .where("seat_hold_sessions.expires_at > ?", at).exists?
    end

    def validate_accessibility!(seats)
      protected_seats = seats.select { |seat| seat.accessible_inventory? && !seat.generally_released?(at: at) }
      return if protected_seats.empty?
      raise HoldError, "Confirm that accessible seating is needed for this party" unless accessibility_attested

      protected_companions = protected_seats.select { |seat| seat.venue_seat.accessibility_kind_companion? }
      wheelchair_groups = seats.select { |seat| seat.venue_seat.accessibility_kind_wheelchair? }
        .map(&:companion_group).compact
      unless protected_companions.all? { |seat| wheelchair_groups.include?(seat.companion_group) }
        raise HoldError, "Companion seats must be selected with their wheelchair location"
      end

      protected_companions.group_by(&:companion_group).each_value do |companions|
        raise HoldError, "A wheelchair location may include at most three companion seats" if companions.length > 3
      end
    end
  end
end
