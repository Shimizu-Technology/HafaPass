# frozen_string_literal: true

module Seating
  class SessionLifecycle
    class SessionError < StandardError; end

    class << self
      def claim!(token:, event:, order:, order_items:)
        session = Credential.find_session(token)
        raise SessionError, "Your seat hold is invalid or expired" unless session

        session.lock!
        unless session.status_active? && session.expires_at > Time.current &&
            session.event_seating_configuration.event_id == event.id
          raise SessionError, "Your seat hold is invalid or expired"
        end

        holds = session.seat_holds.status_active.includes(event_seat: :ticket_type).order(:event_seat_id).lock.to_a
        expected = holds.group_by { |hold| hold.event_seat.ticket_type_id }.transform_values(&:length)
        actual = order_items.index_by(&:ticket_type_id).transform_values(&:quantity)
        raise SessionError, "Selected seats do not match the ticket order" unless expected == actual

        items = order_items.index_by(&:ticket_type_id)
        session.update!(status: :claimed, order: order, claimed_at: Time.current, expires_at: order.expires_at)
        holds.each { |hold| hold.update!(status: :claimed, order_item: items.fetch(hold.event_seat.ticket_type_id)) }
        Audit.record!(event: event, action: "seat_hold.claimed", session: session,
          metadata: { order_id: order.id, event_seat_ids: holds.map(&:event_seat_id) })
        session
      end

      def consume!(session, tickets:)
        session.lock!
        return if session.status_consumed?
        raise SessionError, "Seat hold is not claimed" unless session.status_claimed?

        session.seat_holds.status_claimed.order(:event_seat_id).lock.each do |hold|
          ticket = tickets.find { |candidate| candidate.event_seat_id == hold.event_seat_id }
          raise SessionError, "A ticket was not issued for every selected seat" unless ticket

          hold.update!(status: :consumed)
        end
        session.update!(status: :consumed, consumed_at: Time.current)
        Audit.record!(event: session.event_seating_configuration.event, action: "seat_hold.consumed", session: session,
          metadata: { order_id: session.order_id })
      end

      def release!(session, reason:, expired: false, at: Time.current)
        session.lock!
        return if session.status_released? || session.status_expired? || session.status_consumed?

        target = expired ? :expired : :released
        session.seat_holds.where(status: [:active, :claimed]).order(:id).lock.each do |hold|
          hold.update!(status: target, released_at: at, release_reason: reason)
        end
        session.update!(status: target, released_at: at)
        Audit.record!(event: session.event_seating_configuration.event, action: "seat_hold.#{target}", session: session,
          metadata: { reason: reason, order_id: session.order_id }.compact)
      end

      def expire_stale!(event_seat_ids:, at: Time.current)
        ids = SeatHoldSession.where(status: [:active, :claimed]).where("expires_at <= ?", at)
          .joins(:seat_holds).where(seat_holds: { event_seat_id: event_seat_ids }).distinct.pluck(:id)
        SeatHoldSession.where(id: ids).order(:id).lock.each do |session|
          release!(session, reason: "seat_hold_expired", expired: true, at: at)
        end
      end
    end
  end
end
