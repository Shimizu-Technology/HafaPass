# frozen_string_literal: true

require "rails_helper"

# Historical classification and return postings from positive provenance
# (docs/design/never-fulfilled-captures.md §4.5; tests C-10…C-14, M-02-style
# overlap rows). Every fixture is a synthetic pre-A1 history in this test
# database: NULL recording times, app-written evidence in the past, then the
# A1 cutover rows.
RSpec.describe Commerce::NeverFulfilledReconcile do
  include ActiveSupport::Testing::TimeHelpers

  let(:event) { create(:event) }
  let(:captured_at) { 3.days.ago.change(usec: 0) }

  before do
    allow(EmailService).to receive(:send_refund_notification_async)
    allow(StripeProcessingFees).to receive(:require_adjustment_review!)
  end

  def install_cutovers!
    %w[a1_capture_recording a1_return_recording].each do |key|
      ActiveRecord::Base.connection.execute("INSERT INTO financial_cutovers (key) VALUES ('#{key}') ON CONFLICT (key) DO NOTHING")
    end
  end

  def audit!(action, auditable, at:, **metadata)
    travel_to(at) do
      AuditLogger.record!(action: action, auditable: auditable, organization: event.organization, event: event,
        outcome: "succeeded", deduplication_key: "#{action}:#{auditable.class.name}:#{auditable.id}:#{SecureRandom.hex(3)}",
        metadata: metadata)
    end
  end

  # A late capture recorded by the pre-A1 lifecycle: released order, signed
  # receipt, exception within the window, no tickets. Options remove proofs.
  def historical_late_capture(receipt: true, refund_key: false, release: true, items: [[1200, 160, 0, 0]], receipt_changes: {})
    total = items.flatten.sum
    order = create(:order, event: event, status: :expired, completed_at: nil, subtotal_cents: total, service_fee_cents: 0,
      total_cents: total)
    items.each do |proceeds, fee, organizer_fee, tax|
      create(:order_item, order: order, unit_price_cents: proceeds, subtotal_cents: proceeds, organizer_proceeds_cents: proceeds,
        fee_cents: fee, organizer_fee_cents: organizer_fee, tax_cents: tax)
    end
    audit!("order.expired", order, at: captured_at - 5.minutes, reason: "hold_expired") if release
    payment = create(:payment, order: order, provider_payment_id: "pi_hist_#{SecureRandom.hex(4)}", amount_cents: total,
      status: :succeeded, succeeded_at: order.created_at)
    stamp!(payment, :capture_recorded_at, nil, trigger: "payments_capture_recorded_at")
    webhook = if receipt
      travel_to(captured_at) do
        object = { "id" => payment.provider_payment_id, "status" => "succeeded", "amount_received" => total, "currency" => "usd" }
        payload = { "livemode" => payment.provider_environment == "live", "account" => payment.provider_account_id,
          "data" => { "object" => object.merge(receipt_changes.fetch(:object, {})) } }.merge(receipt_changes.fetch(:payload, {}))
        payload = receipt_changes[:anonymized] ? {} : payload
        WebhookEvent.create!(provider: "stripe", provider_event_id: "evt_hist_#{payment.id}", event_type: "payment_intent.succeeded",
          status: :processed, payload: payload,
          provider_created_at: receipt_changes.fetch(:provider_created_at, captured_at - 1.second))
      end
    end
    issue = travel_to(captured_at + 1.second) do
      ReconciliationException.create!(order: order, payment: payment, webhook_event: webhook,
        code: "late_payment_success_after_hold_expiry")
    end
    if refund_key
      travel_to(captured_at + 2.seconds) do
        before_repayment_fence do
          payment.refunds.create!(order: order, provider: "stripe", idempotency_key: Commerce::LateCaptureRefund.idempotency_key(payment),
            amount_cents: total, currency: "usd", status: :pending)
        end
      end
    end
    [order, payment.reload, issue]
  end

  def historical_refund!(payment, amount, at:, audit: true)
    refund = payment.refunds.create!(order: payment.order, provider: "stripe", provider_refund_id: "re_hist_#{SecureRandom.hex(4)}",
      idempotency_key: "provider:stripe:refund:hist_#{SecureRandom.hex(4)}", amount_cents: amount, currency: "usd",
      status: :succeeded, succeeded_at: at - 30.days) # a backdated business field is never recording evidence
    stamp!(refund, :success_recorded_at, nil, trigger: "refunds_success_recorded_at")
    audit!("refund.succeeded", refund, at: at, order_id: payment.order_id, payment_id: payment.id) if audit
    refund.reload
  end

  def historical_loss!(payment, amount, at:)
    dispute = Dispute.create!(order: payment.order, payment: payment, provider: "stripe", provider_dispute_id: "dp_hist_#{SecureRandom.hex(4)}",
      amount_cents: amount, currency: "usd", status: :lost, opened_at: at - 1.day, closed_at: at)
    stamp!(dispute, :loss_recorded_at, nil, trigger: "disputes_recorded_at")
    audit!("dispute.lost", dispute, at: at, order_id: payment.order_id, payment_id: payment.id)
    dispute.reload
  end

  it "reports first, then classifies with backfill provenance and posts positively matched movements at their evidence times" do
    order, payment, issue = historical_late_capture
    refund = historical_refund!(payment, 500, at: captured_at + 1.hour)
    loss = historical_loss!(payment, 1360, at: captured_at + 1.day)
    install_cutovers!

    dry = described_class.call
    expect(dry.counts).to eq("classify" => 1)
    expect(dry.assessments.sole).to have_attributes(payment_id: payment.id, movement_count: 2)
    expect(UnfulfilledCapture.count + BuyerReturnPosting.count).to eq(0)

    report = described_class.call(dry_run: false)
    expect(report.counts).to eq("classify" => 1)
    capture = UnfulfilledCapture.find_by!(payment: payment)
    receipt = WebhookEvent.find_by!(provider_event_id: "evt_hist_#{payment.id}")
    expect(capture).to have_attributes(provenance: "backfill", capture_scope: "order", code: issue.code,
      capture_recorded_at: receipt.created_at, components: [1200, 160, 0, 0])
    expect(capture.provenance_evidence).to include("source" => "reconcile", "reconciliation_exception_id" => issue.id,
      "webhook_event_id" => receipt.id, "capture_recording" => "backfill")
    expect(order.reload.never_fulfilled_at).to eq(capture.created_at)

    postings = capture.buyer_return_postings.in_sequence.to_a
    refund_audit = AuditLog.find_by!(auditable: refund, action: "refund.succeeded")
    expect(postings.map { |p| [p.kind, p.source_id, p.applied_cents, p.excess_cents, p.recording_source] })
      .to eq([["refund", refund.id, 500, 0, "backfill"], ["dispute_loss", loss.id, 860, 500, "backfill"]])
    expect(postings.first).to have_attributes(recorded_at: refund_audit.created_at, recognized_at: refund_audit.created_at)
    expect(postings.first.evidence).to include("recording_audit_id" => refund_audit.id,
      "business_succeeded_at" => refund.succeeded_at.utc.iso8601(6))

    # Idempotent: a second run changes nothing.
    expect { expect(described_class.call(dry_run: false).counts).to eq({}) }
      .not_to(change { [UnfulfilledCapture.count, BuyerReturnPosting.count, ReconciliationException.count] })
  end

  # A1-R1 review finding 5: the signed receipt proves the capture only with
  # its exact amount, currency, mode, account and time; any mismatch, or a
  # payload retention already cleared, quarantines before anything is written.
  it "quarantines a signed receipt that does not prove this exact capture, before writing" do
    cases = {
      "receipt_amount_mismatch" => { object: { "amount_received" => 1359 } },
      "receipt_currency_mismatch" => { object: { "currency" => "eur" } },
      "receipt_not_succeeded" => { object: { "status" => "processing" } },
      "receipt_mode_mismatch" => { payload: { "livemode" => true } },
      "receipt_account_mismatch" => { payload: { "account" => "acct_someone_else" } },
      "receipt_time_inconsistent" => { provider_created_at: captured_at + 1.day },
      "receipt_time_unknown" => { provider_created_at: nil },
      # Cleared before any release kept its identity (a pre-A1 privacy request).
      "receipt_identity_missing" => { anonymized: true },
      "receipt_names_another_payment" => { object: { "id" => "pi_someone_else" } }
    }
    payments = cases.transform_values { |changes| historical_late_capture(receipt_changes: changes)[1] }
    install_cutovers!

    report = described_class.call(dry_run: false)
    reasons = report.assessments.to_h { |item| [item.payment_id, [item.disposition, item.reason]] }
    cases.each_key { |reason| expect(reasons.fetch(payments.fetch(reason).id)).to eq(["ambiguous", reason]) }
    expect(UnfulfilledCapture.count + BuyerReturnPosting.count).to eq(0)
    expect(ReconciliationException.where(code: described_class::AMBIGUOUS_CODE).count).to eq(cases.size)
  end

  # A1-R1 recheck: retention or a privacy request clearing the payload of a
  # receipt (from either release) keeps its provider identity, so the
  # capture is still proven exactly afterwards.
  it "still proves the capture from the identity kept when retention clears the receipt payload" do
    _order, payment, issue = historical_late_capture
    receipt = issue.webhook_event
    expect(receipt.provider_payment_intent_id).to be_nil # written before A1-R1 kept it
    WebhookEvent.where(id: receipt.id).update_all(payload: {}, retention_anonymized_at: Time.current)
    expect(receipt.reload).to have_attributes(payload: {}, provider_payment_intent_id: payment.provider_payment_id,
      provider_object_id: payment.provider_payment_id, provider_amount_cents: payment.amount_cents, provider_currency: "usd",
      provider_livemode: payment.provider_environment == "live")
    install_cutovers!

    expect(described_class.call(dry_run: false).counts).to eq("classify" => 1)
    expect(UnfulfilledCapture.find_by!(payment: payment).provenance_evidence).to include("webhook_event_id" => receipt.id)
  end

  it "accepts the late-capture refund key as lifecycle evidence when no receipt is linked" do
    _order, payment, = historical_late_capture(receipt: false, refund_key: true)
    install_cutovers!
    expect(described_class.call(dry_run: false).counts).to eq("classify" => 1)
    expect(UnfulfilledCapture.find_by!(payment: payment).provenance_evidence).to include("late_capture_refund_id")
  end

  it "never classifies from a hand-entered exception or timing alone" do
    _order, payment, = historical_late_capture(receipt: false)
    install_cutovers!
    report = described_class.call(dry_run: false)
    expect(report.assessments.sole).to have_attributes(disposition: "ambiguous", reason: "no_lifecycle_evidence")
    expect(UnfulfilledCapture.count).to eq(0)
    issue = ReconciliationException.find_by!(payment: payment, code: described_class::AMBIGUOUS_CODE)
    expect(issue.details).to include("reason" => "no_lifecycle_evidence")
    # Finance owns it from here: later runs hold, and never add a second item.
    expect(described_class.call(dry_run: false).assessments.sole.disposition).to eq("held")
    expect(ReconciliationException.where(code: described_class::AMBIGUOUS_CODE).count).to eq(1)
  end

  it "quarantines missing proofs and ambiguous cross-payment evidence" do
    _o1, no_release, = historical_late_capture(release: false)
    o2, second_capture, = historical_late_capture
    create(:payment, order: o2, provider_payment_id: "pi_hist_other", status: :succeeded, succeeded_at: Time.current)
    o3, unattributed, = historical_late_capture
    o3.refunds.create!(provider: "stripe", provider_refund_id: "re_hist_nopay", idempotency_key: "hist:nopay", amount_cents: 100,
      currency: "usd", status: :succeeded)
    _o4, untimed, = historical_late_capture
    historical_refund!(untimed, 100, at: captured_at + 1.hour, audit: false)
    _o5, late_key, = historical_late_capture(receipt: false)
    other = create(:payment, order: create(:order, event: event), status: :succeeded, succeeded_at: Time.current)
    other.refunds.create!(order: other.order, provider: "stripe", idempotency_key: Commerce::LateCaptureRefund.idempotency_key(late_key),
      amount_cents: 100, currency: "usd", status: :pending)
    install_cutovers!

    reasons = described_class.call.assessments.to_h { |item| [item.payment_id, [item.disposition, item.reason]] }
    expect(reasons).to include(
      no_release.id => ["ambiguous", "release_audit_missing"],
      second_capture.id => ["ambiguous", "ownership_ambiguous"],
      unattributed.id => ["ambiguous", "unattributed_movement"],
      untimed.id => ["ambiguous", "movement_recording_time_unknown"],
      late_key.id => ["ambiguous", "late_capture_refund_on_another_payment"])
    described_class.call(dry_run: false)
    expect(UnfulfilledCapture.count).to eq(0)
    expect(ReconciliationException.where(code: described_class::AMBIGUOUS_CODE).count).to eq(5)
  end

  it "writes nothing but a restatement item when the event's results are published" do
    # Finalized before the late capture was recorded (the database refuses a
    # finalization while the capture's hold is open).
    Settlement.new(event: event, organization: event.organization, status: :finalized, version: 1, source_digest: "hist",
      calculated_at: 1.day.ago, finalized_at: 1.day.ago).save!(validate: false)
    _order, payment, = historical_late_capture
    install_cutovers!

    report = described_class.call(dry_run: false)
    expect(report.assessments.sole).to have_attributes(disposition: "restatement")
    expect(UnfulfilledCapture.count).to eq(0)
    issue = ReconciliationException.find_by!(payment: payment, code: described_class::RESTATEMENT_CODE)
    expect(issue.details["settlement_ids"]).to eq(Settlement.where(event: event).pluck(:id))
  end

  it "re-assesses under the locks instead of trusting an earlier assessment" do
    order, payment, = historical_late_capture
    install_cutovers!
    reconciler = described_class.new(payment)
    expect(reconciler.run!(dry_run: true).disposition).to eq("classify")
    create(:ticket, order: order, event: event, ticket_type: order.order_items.first.ticket_type) # issued after the report
    expect(reconciler.run!(dry_run: false)).to have_attributes(disposition: "ambiguous", reason: "active_tickets")
    expect(UnfulfilledCapture.count).to eq(0)
  end

  it "posts a classified payment's movement that an older worker recorded unposted, and clears its quarantine" do
    _order, payment, capture = classified_capture(items: [[1200, 160, 0, 0]], event: event)
    connection = ActiveRecord::Base.connection
    connection.execute("ALTER TABLE never_fulfilled_captures DISABLE TRIGGER never_fulfilled_captures_append_only")
    UnfulfilledCapture.where(id: capture.id).update_all(capture_recorded_at: 1.hour.ago)
    connection.execute("ALTER TABLE never_fulfilled_captures ENABLE TRIGGER never_fulfilled_captures_append_only")
    capture.reload
    refund = historical_refund!(payment, 300, at: 1.minute.ago)
    Order.transaction { Commerce::BuyerReturnPostings.record_refund!(refund) }
    quarantine = ReconciliationException.find_by!(payment: payment, code: Commerce::BuyerReturnPostings::QUARANTINE_CODE)
    install_cutovers!

    expect(described_class.unposted_movement_payment_ids).to eq([payment.id])
    expect(described_class.call(dry_run: false).counts).to eq("post" => 1)
    audit = AuditLog.find_by!(auditable: refund, action: "refund.succeeded")
    expect(capture.buyer_return_postings.sole).to have_attributes(kind: "refund", recording_source: "backfill",
      recorded_at: audit.created_at, recognized_at: audit.created_at)
    expect(quarantine.reload).to be_resolved
    expect(described_class.unposted_movement_payment_ids).to be_empty
  end

  it "leaves a fulfilled sale and its second capture's history alone" do
    order = create(:order, :pending, event: event, subtotal_cents: 1200, service_fee_cents: 160, total_cents: 1360)
    payment_a = create(:payment, order: order, status: :succeeded, succeeded_at: Time.current)
    order.update!(status: :completed, completed_at: Time.current, fulfilled_by_payment_id: payment_a.id)
    historical_refund!(payment_a, 500, at: 1.hour.ago)
    install_cutovers!
    expect(described_class.candidate_payment_ids).to be_empty
    expect(described_class.call_for_payment(payment_a, dry_run: false)).to have_attributes(disposition: "reconciled",
      reason: "not_a_candidate")
    expect(ReconciliationException.count + UnfulfilledCapture.count + BuyerReturnPosting.count).to eq(0)
  end
end
