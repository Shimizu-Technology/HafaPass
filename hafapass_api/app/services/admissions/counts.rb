# frozen_string_literal: true

module Admissions
  # Aggregate in PostgreSQL: a scan ACK must not instantiate the event's ticket,
  # payment, refund or dispute graph. These are current persisted states, not
  # saleable stock or physical occupancy. `remaining` is the legacy issued alias.
  class Counts
    # Ruby String#blank?'s Unicode whitespace, independent of PostgreSQL locale.
    BLANK_CHARACTERS = "\u0009\u000a\u000b\u000c\u000d \u0085\u00a0\u1680\u2000\u2001\u2002\u2003\u2004\u2005\u2006\u2007\u2008\u2009\u200a\u2028\u2029\u202f\u205f\u3000".freeze

    def self.call(event:)
      new(event).call
    end

    def initialize(event)
      @event = event
    end

    def call
      row = ActiveRecord::Base.connection.select_one(sql).symbolize_keys.transform_values(&:to_i)
      row.merge(remaining: row.fetch(:issued))
    end

    private

    def sql
      <<~SQL
        WITH refund_totals AS (
          SELECT r.order_id, SUM(r.amount_cents) AS reserved, BOOL_OR(r.status = #{Refund.statuses.fetch('pending')}) AS pending
          FROM refunds r JOIN orders o ON o.id = r.order_id
          WHERE o.event_id = #{@event.id.to_i} AND r.status IN (#{Refund.statuses.values_at('pending', 'succeeded').join(',')})
          GROUP BY r.order_id
        ), eligible_orders AS (
          SELECT o.id FROM orders o LEFT JOIN refund_totals rf ON rf.order_id = o.id
          WHERE o.event_id = #{@event.id.to_i}
            AND o.status IN (#{Order.statuses.values_at('completed', 'partially_refunded').join(',')})
            AND NOT (o.total_cents > 0 AND COALESCE(rf.pending, FALSE) AND rf.reserved >= o.total_cents)
            AND NOT EXISTS (SELECT 1 FROM disputes d WHERE d.order_id = o.id AND d.status IN (#{Dispute.statuses.values_at('open', 'lost').join(',')}))
            AND #{payment_predicate}
        )
        SELECT COUNT(*) AS total,
          COUNT(*) FILTER (WHERE t.status = #{Ticket.statuses.fetch('issued')}) AS issued,
          COUNT(*) FILTER (WHERE t.status = #{Ticket.statuses.fetch('checked_in')}) AS admitted,
          COUNT(*) FILTER (WHERE t.status = #{Ticket.statuses.fetch('cancelled')}) AS cancelled,
          COUNT(*) FILTER (WHERE t.status = #{Ticket.statuses.fetch('issued')} AND eo.id IS NOT NULL
            AND #{@event.published? ? 'TRUE' : 'FALSE'}
            AND NOT EXISTS (SELECT 1 FROM ticket_inventory_retentions ir WHERE ir.ticket_id = t.id)
            AND NOT EXISTS (SELECT 1 FROM refund_tickets rt JOIN refunds r ON r.id = rt.refund_id
              WHERE rt.ticket_id = t.id AND rt.released_at IS NULL AND r.status = #{Refund.statuses.fetch('pending')})) AS eligible_unadmitted,
          (SELECT COUNT(*) FROM admission_actions a WHERE a.event_id = #{@event.id.to_i} AND a.result = #{AdmissionAction.results.fetch('conflict')}) AS conflicts,
          (SELECT COUNT(*) FROM admission_actions a WHERE a.event_id = #{@event.id.to_i} AND a.result = #{AdmissionAction.results.fetch('rejected')}) AS rejected
        FROM tickets t LEFT JOIN eligible_orders eo ON eo.id = t.order_id WHERE t.event_id = #{@event.id.to_i}
      SQL
    end

    def payment_predicate
      return "TRUE" unless Rails.env.production?

      environments = SiteSetting.instance.payment_mode == "test" ? "'live','test'" : "'live'"
      <<~SQL.squish
        (o.total_cents <= 0 OR EXISTS (
          SELECT 1 FROM payments p WHERE p.order_id = o.id
            AND p.status IN (#{Payment.statuses.values_at('succeeded', 'partially_refunded').join(',')})
            AND p.amount_cents >= o.total_cents AND p.currency = o.currency
            AND #{present_sql('p.provider_payment_id')} AND LEFT(p.provider_payment_id, 4) <> 'sim_'
            AND (p.provider_payload -> 'simulated') IS DISTINCT FROM 'true'::jsonb
            AND (p.provider <> 'stripe' OR (p.provider_environment IN (#{environments}) AND #{present_sql('p.provider_platform_account_id')}))
        ))
      SQL
    end

    def present_sql(column)
      # Keep whitespace out of the literal while payment_predicate is squished.
      characters = BLANK_CHARACTERS.codepoints.map { |point| "\\#{point.to_s(16).rjust(4, '0')}" }.join
      "LENGTH(translate(#{column}, U&'#{characters}', '')) > 0"
    end
  end
end
