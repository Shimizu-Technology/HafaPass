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
    archive: { from: %w[draft cancelled completed], to: "archived" },
    # Admin-only (Api::V1::Admin::EventsController#unarchive): returns an event
    # to the status it was archived from, so a missing statement can be finalized.
    unarchive: { from: %w[archived], to: :previous }
  }.freeze

  # Payouts that still reserve or may move money for the event.
  OPEN_PAYOUT_STATUSES = %i[pending processing held].freeze

  def self.call(...)
    new(...).call
  end

  def initialize(event:, action:, actor:, reason: nil, at: Time.current, expected_refund_count: nil,
    expected_refund_total_cents: nil)
    @event = event
    @action = action.to_sym
    @actor = actor
    @reason = reason.to_s.strip.presence
    @at = at
    @expected_refund_count = expected_refund_count
    @expected_refund_total_cents = expected_refund_total_cents
  end

  def call
    transition = TRANSITIONS.fetch(action) { raise TransitionError, "Unsupported event action" }
    buyer_change = nil
    refund_run = nil

    event.organization.with_lock do
      event.with_lock do
        unless transition[:from].include?(event.status)
          raise TransitionError, "Cannot #{action} an event with status #{event.status}"
        end
        validate_action!
        if action == :cancel && !@expected_refund_count.nil?
          preview = EventCancellationRefunds.preview(event)
          if preview[:count] != @expected_refund_count || preview[:total_cents] != @expected_refund_total_cents
            raise TransitionError, "Refund total changed. Review the current count and amount before cancelling."
          end
        end

        from_status = event.status
        to_status = transition[:to] == :previous ? status_before_archive : transition[:to]
        before_data = event_snapshot
        attributes = { status: to_status }
        attributes[:published_at] = at if action == :publish && event.published_at.blank?
        event.update!(attributes)
        event.event_state_changes.create!(
          actor_user: actor,
          action: action,
          from_status: from_status,
          to_status: to_status,
          reason: reason,
          occurred_at: at
        )
        buyer_change = record_buyer_change!(before_data) if %i[postpone cancel].include?(action)
        refund_run = EventCancellationRefunds.prepare!(event: event, actor: actor) if action == :cancel
        EmailService.send_event_change_notifications_async(buyer_change) if buyer_change
      end
    end

    EventCancellationRefundJob.perform_later(refund_run.id) if refund_run

    event
  rescue ActiveRecord::RecordInvalid => e
    raise TransitionError, e.record.errors.full_messages.to_sentence
  end

  private

  attr_reader :event, :action, :actor, :reason, :at

  def validate_action!
    if %i[publish resume].include?(action)
      checklist = event.publish_checklist(at: at)
      unless checklist.all? { |item| item[:complete] || !item[:required_to_publish] }
        raise TransitionError.new("Complete the publishing checklist before publishing", checklist: checklist)
      end
    end

    if %i[postpone cancel unarchive].include?(action) && reason.blank?
      raise TransitionError, "A reason is required to #{action} this event"
    end

    if action == :complete && (event.ends_at.blank? || event.ends_at > at)
      raise TransitionError, "An event cannot be completed before it ends"
    end

    if action == :archive && !event.draft? && (problem = archive_blocker)
      raise TransitionError, problem
    end
  end

  # Archived events cannot be finalized (Settlements::Finalizer accepts only
  # completed or cancelled events), so archiving early would strand the
  # organizer's money. A sold event may be archived only when its latest
  # finalized statement still matches the ledger and nothing is left to pay.
  def archive_blocker
    settlement = event.settlements.status_finalized.order(version: :desc).first
    unless settlement
      return "Finalize this event's statement before archiving it. Archived events cannot be finalized or paid out."
    end

    preview = Settlements::Calculator.call(event).attributes
    if settlement.source_digest != preview[:source_digest]
      return "Activity changed after statement version #{settlement.version}, including any payout. " \
        "Finalize a new version before archiving."
    end
    if event.payouts.where(status: OPEN_PAYOUT_STATUSES).exists?
      return "A payout for this event is still in progress or on hold. Archive it after the payout is resolved."
    end
    remaining = preview[:payable_cents] - preview[:paid_cents]
    if remaining.positive?
      return "#{format('$%<dollars>d.%<cents>02d', dollars: remaining / 100, cents: remaining % 100)} is still payable for this event. Pay it out and finalize a new version before archiving."
    end
    if preview[:reserve_cents].positive?
      return "A reserve is still held for this event. Release or settle it and finalize a new version before archiving."
    end

    nil
  end

  def status_before_archive
    previous = event.event_state_changes.where(action: "archive").order(:occurred_at, :id).last&.from_status
    unless TRANSITIONS.fetch(:archive)[:from].include?(previous)
      raise TransitionError, "This event's status before archiving is not recorded"
    end

    previous
  end

  def record_buyer_change!(before_data)
    event.event_changes.create!(
      actor_user: actor,
      change_type: action == :postpone ? "postponed" : "cancelled",
      reason: reason,
      before_data: before_data,
      after_data: event_snapshot,
      occurred_at: at
    )
  end

  def event_snapshot
    {
      status: event.status,
      starts_at: event.starts_at&.iso8601,
      ends_at: event.ends_at&.iso8601,
      doors_open_at: event.doors_open_at&.iso8601,
      venue_name: event.venue_name,
      venue_address: event.venue_address
    }
  end
end
