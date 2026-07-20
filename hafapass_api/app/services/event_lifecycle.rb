# frozen_string_literal: true

class EventLifecycle
  class TransitionError < StandardError
    attr_reader :checklist

    def initialize(message, checklist: nil)
      @checklist = checklist
      super(message)
    end
  end

  TRANSITIONS = {
    publish: { from: %w[draft], to: "published" },
    postpone: { from: %w[published], to: "postponed" },
    resume: { from: %w[postponed], to: "published" },
    cancel: { from: %w[published postponed], to: "cancelled" },
    complete: { from: %w[published], to: "completed" },
    archive: { from: %w[draft cancelled completed], to: "archived" }
  }.freeze

  def self.call(...)
    new(...).call
  end

  def initialize(event:, action:, actor:, reason: nil, at: Time.current)
    @event = event
    @action = action.to_sym
    @actor = actor
    @reason = reason.to_s.strip.presence
    @at = at
  end

  def call
    transition = TRANSITIONS.fetch(action) { raise TransitionError, "Unsupported event action" }

    event.with_lock do
      unless transition[:from].include?(event.status)
        raise TransitionError, "Cannot #{action} an event with status #{event.status}"
      end
      validate_action!

      from_status = event.status
      attributes = { status: transition[:to] }
      attributes[:published_at] = at if action == :publish && event.published_at.blank?
      event.update!(attributes)
      event.event_state_changes.create!(
        actor_user: actor,
        action: action,
        from_status: from_status,
        to_status: transition[:to],
        reason: reason,
        occurred_at: at
      )
    end

    event
  rescue ActiveRecord::RecordInvalid => e
    raise TransitionError, e.record.errors.full_messages.to_sentence
  end

  private

  attr_reader :event, :action, :actor, :reason, :at

  def validate_action!
    if %i[publish resume].include?(action)
      checklist = event.publish_checklist(at: at)
      unless checklist.all? { |item| item[:complete] }
        raise TransitionError.new("Complete the publishing checklist before publishing", checklist: checklist)
      end
    end

    if %i[postpone cancel].include?(action) && reason.blank?
      raise TransitionError, "A reason is required to #{action} this event"
    end

    if action == :complete && (event.ends_at.blank? || event.ends_at > at)
      raise TransitionError, "An event cannot be completed before it ends"
    end
  end
end
