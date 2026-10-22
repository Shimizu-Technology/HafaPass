# frozen_string_literal: true

# An admin's "Resume sales" for an event whose sales were suspended (a Gate I
# pilot pause or abort, or a seating pause). Clears the suspension so a
# general-admission organizer is never left stuck behind an optional record.
# Audited; a paused or aborted pilot run stays as it was, as history.
class EventSalesSuspension
  class SuspensionError < StandardError; end

  MAX_NOTE_LENGTH = 1000

  def self.lift!(event:, actor:, note: nil, request: nil)
    raise SuspensionError, "Administrator access is required" unless actor&.persisted? && actor.admin?

    note = note.is_a?(String) ? note.strip.presence : nil
    raise SuspensionError, "Keep the note under #{MAX_NOTE_LENGTH} characters" if note && note.length > MAX_NOTE_LENGTH

    event.with_lock do
      raise SuspensionError, "Sales for this event are not paused" if event.sales_suspended_at.nil?

      before_data = { "sales_suspended_at" => event.sales_suspended_at.iso8601,
        "sales_suspension_reason" => event.sales_suspension_reason }
      event.update!(sales_suspended_at: nil, sales_suspension_reason: nil)
      AuditLogger.record!(action: "event.sales_resumed", auditable: event, actor: actor, organization: event.organization,
        before_data: before_data, after_data: { "sales_suspended_at" => nil }, metadata: { note: note }.compact,
        request: request)
    end
    event
  rescue ActiveRecord::RecordInvalid => e
    raise SuspensionError, e.record.errors.full_messages.to_sentence
  end
end
