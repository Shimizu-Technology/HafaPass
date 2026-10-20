# frozen_string_literal: true

# Platform-admin takedown for an event that violates policy. A hold stops all
# sales (online, box office, seat holds and payment resumption all check
# Event#sales_open?) and, with the "hidden" scope, removes the event from
# public pages. It never changes the lifecycle status, deletes data, cancels
# tickets or refunds anyone: existing ticket holders can still be admitted and
# refunds stay a separate, deliberate decision. Every change is audited.
class EventPolicyHold
  class HoldError < StandardError; end

  MAX_REASON_LENGTH = 1000

  def self.place!(event:, actor:, scope:, reason:, request: nil)
    authorize!(actor)
    scope = scope.to_s
    raise HoldError, "Choose whether to pause sales or hide the event" unless Event::POLICY_HOLD_SCOPES.include?(scope)

    reason = normalized_reason!(reason)
    event.with_lock do
      raise HoldError, "This event is already on a policy hold. Lift it before placing a new one." if event.policy_hold?

      before_data = snapshot(event)
      event.update!(policy_hold_at: Time.current, policy_hold_scope: scope, policy_hold_reason: reason,
        policy_hold_by_user: actor)
      AuditLogger.record!(action: "event.policy_hold_placed", auditable: event, actor: actor,
        organization: event.organization, before_data: before_data, after_data: snapshot(event),
        metadata: { reason: reason }, request: request)
    end
    event
  rescue ActiveRecord::RecordInvalid => e
    raise HoldError, e.record.errors.full_messages.to_sentence
  end

  def self.lift!(event:, actor:, reason:, request: nil)
    authorize!(actor)
    reason = normalized_reason!(reason)
    event.with_lock do
      raise HoldError, "This event is not on a policy hold" unless event.policy_hold?

      before_data = snapshot(event)
      event.update!(policy_hold_at: nil, policy_hold_scope: nil, policy_hold_reason: nil, policy_hold_by_user: nil)
      AuditLogger.record!(action: "event.policy_hold_lifted", auditable: event, actor: actor,
        organization: event.organization, before_data: before_data, after_data: snapshot(event),
        metadata: { reason: reason }, request: request)
    end
    event
  rescue ActiveRecord::RecordInvalid => e
    raise HoldError, e.record.errors.full_messages.to_sentence
  end

  def self.authorize!(actor)
    raise HoldError, "Administrator access is required" unless actor&.persisted? && actor.admin?
  end
  private_class_method :authorize!

  def self.normalized_reason!(reason)
    text = reason.is_a?(String) ? reason.strip : ""
    raise HoldError, "A reason is required" if text.blank?
    raise HoldError, "Keep the reason under #{MAX_REASON_LENGTH} characters" if text.length > MAX_REASON_LENGTH

    text
  end
  private_class_method :normalized_reason!

  def self.snapshot(event)
    {
      "status" => event.status,
      "policy_hold_scope" => event.policy_hold_scope,
      "policy_hold_reason" => event.policy_hold_reason,
      "policy_hold_at" => event.policy_hold_at&.iso8601
    }
  end
  private_class_method :snapshot
end
