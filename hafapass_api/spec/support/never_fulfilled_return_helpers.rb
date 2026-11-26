# frozen_string_literal: true

require "ostruct"

# Fixtures for never-fulfilled return postings (A1 tranche 3). Components are
# built exactly, item by item, so the snapshot K is known; the classification
# row goes straight to the database triggers.
module NeverFulfilledReturnHelpers
  # items: [[proceeds, fee, organizer_fee, tax], ...], in RefundItem walk order.
  def classified_capture(items:, event: create(:event), status: :expired, intent: "pi_nfr_#{SecureRandom.hex(4)}")
    total = items.flatten.sum
    order = create(:order, event: event, status: status, completed_at: nil, subtotal_cents: total,
      service_fee_cents: 0, total_cents: total)
    items.each do |proceeds, fee, organizer_fee, tax|
      create(:order_item, order: order, unit_price_cents: proceeds + organizer_fee, quantity: 1,
        subtotal_cents: proceeds + organizer_fee, organizer_proceeds_cents: proceeds, fee_cents: fee,
        organizer_fee_cents: organizer_fee, tax_cents: tax)
    end
    payment = create(:payment, order: order, provider_payment_id: intent, amount_cents: total, status: :succeeded,
      succeeded_at: Time.current)
    [order, payment, classify_order_scope!(order, payment)]
  end

  def classify_order_scope!(order, payment)
    items = order.order_items
    UnfulfilledCapture.create!(order: order, payment: payment, capture_scope: "order",
      code: "late_payment_success_after_hold_expiry", captured_cents: payment.amount_cents, currency: payment.currency,
      proceeds_cents: items.sum(:organizer_proceeds_cents), fee_cents: items.sum(:fee_cents),
      organizer_fee_cents: items.sum(:organizer_fee_cents), tax_cents: items.sum(:tax_cents),
      processing_bearer: "platform", dispute_fee_bearer: "platform", allocation_policy: "item_record",
      policy_version: Commerce::NeverFulfilledClassification::POLICY_VERSION, provenance: "lifecycle").reload
  end

  # Writes a database-stamped time directly, as a migrated database would
  # hold it, by disabling only that stamp trigger inside the transaction.
  def stamp!(record, column, time, trigger:)
    connection = ActiveRecord::Base.connection
    table = record.class.table_name
    connection.execute("ALTER TABLE #{table} DISABLE TRIGGER #{trigger}")
    record.class.where(id: record.id).update_all(column => time)
  ensure
    connection.execute("ALTER TABLE #{table} ENABLE TRIGGER #{trigger}")
  end

  # travel_to moves only the application clock, but A1's recording times are
  # stamped by the database clock. This re-stamps one payment's capture, its
  # classification and its return postings (with their refunds and losses) to
  # the application times the travelling fixture wrote, as a database whose
  # clock had been at those times would hold them. Recognition stays
  # GREATEST(return recorded, capture recorded).
  ALIGNED_TRIGGERS = {
    "payments" => "payments_capture_recorded_at", "never_fulfilled_captures" => "never_fulfilled_captures_append_only",
    "buyer_return_postings" => "buyer_return_postings_append_only", "refunds" => "refunds_success_recorded_at",
    "disputes" => "disputes_recorded_at"
  }.freeze

  def align_recording_times!(payment)
    connection = ActiveRecord::Base.connection
    triggers = ALIGNED_TRIGGERS
    payment.reload
    captured_at = payment.succeeded_at
    capture = UnfulfilledCapture.find_by(payment_id: payment.id)
    triggers.each { |table, trigger| connection.execute("ALTER TABLE #{table} DISABLE TRIGGER #{trigger}") }
    Payment.where(id: payment.id).update_all(capture_recorded_at: captured_at)
    return unless capture

    UnfulfilledCapture.where(id: capture.id).update_all(capture_recorded_at: captured_at)
    times = payment.refunds.succeeded.to_h { |refund| [[refund, :success_recorded_at], refund.succeeded_at] }
      .merge(Dispute.lost.where(payment_id: payment.id).to_h { |dispute| [[dispute, :loss_recorded_at], dispute.closed_at] })
      .compact
    times.each { |(source, column), time| source.class.where(id: source.id).update_all(column => time) }
    BuyerReturnPosting.where(never_fulfilled_capture_id: capture.id).find_each do |posting|
      moved = times.find { |(source, _column), _time| posting.source == source && !posting.reversal? }
      recorded_at = moved ? moved.last : posting.recorded_at
      BuyerReturnPosting.where(id: posting.id).update_all(capture_recorded_at: captured_at, recorded_at: recorded_at,
        recognized_at: [recorded_at, captured_at].max)
    end
  ensure
    triggers.each { |table, trigger| connection.execute("ALTER TABLE #{table} ENABLE TRIGGER #{trigger}") }
  end

  # Rows an older release wrote before the A1-R1 repayment fence existed:
  # runs the block with only that trigger disabled, inside the transaction.
  def before_repayment_fence
    connection = ActiveRecord::Base.connection
    connection.execute("ALTER TABLE refunds DISABLE TRIGGER refunds_repayment_fence")
    yield
  ensure
    connection.execute("ALTER TABLE refunds ENABLE TRIGGER refunds_repayment_fence")
  end

  def ingest_provider_refund!(payment, amount, id: "re_nfr_#{SecureRandom.hex(4)}", status: "succeeded")
    Commerce::ExternalRefundRecovery.ingest!(payment: payment, provider_refund: OpenStruct.new(id: id, amount: amount,
      currency: "usd", payment_intent: payment.provider_payment_id, status: status, metadata: {}))
    Refund.find_by!(provider_refund_id: id)
  end

  def stripe_webhook!(type, object, event_id: "evt_nfr_#{SecureRandom.hex(4)}", created: nil)
    payload = { "id" => event_id, "type" => type, "data" => { "object" => object.deep_stringify_keys } }
    event = Stripe::Event.construct_from(payload.merge("created" => created&.to_i).compact)
    StripeWebhookProcessor.call(event: event, payload: payload)
  end

  def dispute_object(payment, id, amount: payment.amount_cents, status: "needs_response")
    { id: id, object: "dispute", payment_intent: payment.provider_payment_id, amount: amount, currency: "usd",
      status: status, reason: "fraudulent" }
  end

  def lose_dispute!(payment, id, amount: payment.amount_cents)
    stripe_webhook!("charge.dispute.created", dispute_object(payment, id, amount: amount))
    stripe_webhook!("charge.dispute.closed", dispute_object(payment, id, amount: amount, status: "lost"))
    Dispute.find_by!(provider_dispute_id: id)
  end

  def win_late!(payment, id, amount: payment.amount_cents, type: "charge.dispute.closed", event_id: nil)
    stripe_webhook!(type, dispute_object(payment, id, amount: amount, status: "won"),
      **{ event_id: event_id }.compact)
    Dispute.find_by!(provider_dispute_id: id)
  end

  def posting_rows(capture)
    capture.buyer_return_postings.in_sequence.map do |posting|
      [posting.kind, posting.gross_cents, posting.applied_cents, posting.excess_cents, posting.components]
    end
  end

  def ledger(capture)
    Commerce::BuyerReturnLedger.for(capture.reload)
  end
end

RSpec.configure { |config| config.include NeverFulfilledReturnHelpers }
