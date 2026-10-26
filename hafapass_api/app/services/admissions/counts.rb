# frozen_string_literal: true

module Admissions
  # These are persisted ticket states, not saleable stock or physical occupancy.
  class Counts
    def self.call(event:)
      tickets = event.tickets.includes(:event, :inventory_retention, :pending_refund_tickets,
        order: [:payments, :refunds, :disputes]).to_a
      statuses = tickets.group_by(&:status).transform_values(&:size)
      issued = statuses.fetch("issued", 0)
      payment_mode = SiteSetting.instance.payment_mode
      {
        total: tickets.size,
        issued: issued,
        remaining: issued, # Legacy alias; never a promise of admission eligibility.
        eligible_unadmitted: tickets.count { |ticket| ticket.issued? &&
          ticket.order.ticket_fulfilled?(payment_mode: payment_mode) && !ticket.order.ticket_access_blocked? &&
          !ticket.refund_pending? && !ticket.inventory_retained? && event.published? },
        admitted: statuses.fetch("checked_in", 0),
        cancelled: statuses.fetch("cancelled", 0),
        conflicts: event.admission_actions.result_conflict.count,
        rejected: event.admission_actions.result_rejected.count
      }
    end
  end
end
