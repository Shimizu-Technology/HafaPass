# frozen_string_literal: true

module Seating
  module Audit
    module_function

    def record!(event:, action:, event_seat: nil, session: nil, ticket: nil, actor: nil, metadata: {})
      SeatAuditEvent.create!(
        event: event,
        event_seat: event_seat,
        seat_hold_session: session,
        ticket: ticket,
        actor_user: actor,
        action: action,
        metadata: metadata,
        occurred_at: Time.current
      )
    end
  end
end
