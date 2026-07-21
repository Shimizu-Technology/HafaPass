# frozen_string_literal: true

class LivePilot
  class InventoryLimitError < StandardError; end

  def self.active_approval(event, at: Time.current, state_digest: nil, rehearsal: nil, live_money: nil)
    return if event.live_money_proof_candidate?

    state_digest ||= PilotReadiness.event_state_digest(event)
    rehearsal ||= EventDayRehearsal.active_approval(event, at: at, state_digest: state_digest)
    return unless rehearsal

    if paid_event?(event)
      live_money ||= LiveMoneyProof.active_approval(event.organization, at: at)
      return unless live_money
    end
    revoked_ids = event.live_pilot_reviews.revocations.select(:parent_review_id)
    scope = event.live_pilot_reviews.approvals
      .where.not(id: revoked_ids)
      .where(event_day_rehearsal_review_id: rehearsal.id)
      .where(event_state_digest: state_digest)
      .where(application_revision: PilotReadiness.application_revision)
      .where("effective_at <= ? AND expires_at > ?", at, at)
    scope = scope.where(live_money_proof_review_id: live_money&.id)
    scope.order(created_at: :desc).first
  end

  def self.pending_submission(event)
    decided_ids = event.live_pilot_reviews.where(decision: [:approval, :rejection]).select(:parent_review_id)
    event.live_pilot_reviews.decision_submission.where.not(id: decided_ids)
      .where("expires_at > ?", Time.current).order(created_at: :desc).first
  end

  def self.latest_approval(event)
    event.live_pilot_reviews.approvals.order(created_at: :desc).first
  end

  def self.current_run(event, at: Time.current)
    approval = active_approval(event, at: at)
    return unless approval

    event.live_pilot_runs.where(live_pilot_review_id: approval.id, status: [:active, :paused])
      .order(created_at: :desc).first
  end

  def self.active_run(event, at: Time.current)
    run = current_run(event, at: at)
    run if run&.status_active?
  end

  def self.latest_run(event)
    event.live_pilot_runs.order(created_at: :desc).first
  end

  def self.status(event)
    state_digest = PilotReadiness.event_state_digest(event)
    rehearsal = EventDayRehearsal.active_approval(event, state_digest: state_digest)
    live_money = LiveMoneyProof.active_approval(event.organization) if paid_event?(event)
    approval = active_approval(
      event, state_digest: state_digest, rehearsal: rehearsal, live_money: live_money
    )
    latest = latest_approval(event)
    run = latest_run(event)
    {
      required: Rails.env.production? && !event.live_money_proof_candidate?,
      prerequisite_ready: rehearsal.present? && (!paid_event?(event) || live_money.present?),
      approved: approval.present?,
      candidate_current: latest.present? && latest.event_state_digest == state_digest &&
        latest.application_revision == PilotReadiness.application_revision &&
        latest.event_day_rehearsal_review_id == rehearsal&.id &&
        latest.live_money_proof_review_id == live_money&.id,
      pending_submission: pending_submission(event), latest_approval: latest, active_approval_id: approval&.id,
      latest_run: run, active_run_id: active_run(event)&.id,
      required_assignments: LivePilotReview::ASSIGNMENT_KEYS,
      required_support_windows: LivePilotReview::SUPPORT_WINDOWS,
      required_thresholds: LivePilotReview::THRESHOLD_FIELDS,
      required_controls: LivePilotReview::CONTROL_KEYS,
      maximum_inventory_cap: LivePilotReview::MAXIMUM_INVENTORY_CAP,
      event_state_digest: state_digest, application_revision: PilotReadiness.application_revision
    }
  end

  def self.list_summary(event)
    reviews = event.live_pilot_reviews.to_a
    decided_ids = reviews.filter_map do |review|
      review.parent_review_id if review.decision_approval? || review.decision_rejection?
    end
    pending = reviews.select do |review|
      review.decision_submission? && review.expires_at > Time.current && !decided_ids.include?(review.id)
    end.max_by(&:created_at)
    latest = reviews.select(&:decision_approval?).max_by(&:created_at)
    run = event.live_pilot_runs.max_by(&:created_at)
    {
      approval_recorded: latest.present?, pending_submission: pending && { id: pending.id, created_at: pending.created_at },
      run_status: run&.status
    }
  end

  def self.enforce_inventory_cap!(event:, requested_quantity:)
    return unless Rails.env.production?
    return if event.live_money_proof_candidate?

    run = active_run(event)
    raise InventoryLimitError, "The bounded live pilot is not actively selling" unless run

    committed = committed_ticket_quantity(event)
    if committed + requested_quantity > run.inventory_cap
      raise InventoryLimitError, "The bounded live-pilot inventory cap has been reached"
    end
  end

  def self.committed_ticket_quantity(event)
    event.orders.where.not(status: [:cancelled, :expired]).joins(:order_items)
      .where(order_items: { item_kind: OrderItem.item_kinds[:ticket] }).sum("order_items.quantity")
  end

  def self.paid_event?(event)
    event.ticket_types.any? do |ticket_type|
      ticket_type.price_cents.positive? || ticket_type.pricing_tiers.any? { |tier| tier.price_cents.positive? }
    end
  end
end
