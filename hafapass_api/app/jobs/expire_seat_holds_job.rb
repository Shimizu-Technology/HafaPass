# frozen_string_literal: true

class ExpireSeatHoldsJob < ApplicationJob
  queue_as :default

  def perform(at = Time.current)
    SeatHoldSession.where(status: [:active, :claimed]).where(expires_at: ..at).find_each do |session|
      if session.status_claimed? && session.order&.pending?
        Commerce::OrderLifecycle.expire!(session.order, at: at)
      else
        Seating::SessionLifecycle.release!(session, reason: "seat_hold_expired", expired: true, at: at)
      end
    rescue StandardError => e
      Sentry.capture_exception(e)
      Rails.logger.error({ event: "seat_hold_expiry_failed", seat_hold_session_id: session.id,
        error_class: e.class.name }.to_json)
    end
  end
end
