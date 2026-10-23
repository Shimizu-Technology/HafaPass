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

    AuditContext.set(actor: actor, source: "admin", request_id: request&.request_id || AuditContext.request_id,
      ip_address: request&.remote_ip || AuditContext.ip_address) do
      event.with_lock do
      raise SuspensionError, "Sales for this event are not paused" if event.sales_suspended_at.nil?

      event.audit_sales_note = note
      event.update!(sales_suspended_at: nil, sales_suspension_reason: nil)
      end
    end
    event
  rescue ActiveRecord::RecordInvalid => e
    raise SuspensionError, e.record.errors.full_messages.to_sentence
  ensure
    event.audit_sales_note = nil
  end
end
