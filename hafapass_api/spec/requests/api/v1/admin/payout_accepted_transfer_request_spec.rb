# frozen_string_literal: true

require "rails_helper"

# A2 recheck findings 2 and 3 (e49e94d2), through the authenticated admin
# endpoint. The provider call runs outside the payout locks; an ordinary
# refund changes the approved statement of an event with a classified
# capture while it is in flight, and the provider then reports the transfer
# paid (a stubbed gateway: the production manual gateway only returns a
# placeholder). The acceptance is kept with its reference, amount and time,
# is never sent again or made ordinary paid, never fails or reverses without
# the bank's exact return evidence, keeps its reservation against a fresh
# payout key, and is booked once as cash out in the CPA evidence.
RSpec.describe "Admin accepted transfer after a statement change", type: :request do
  let(:admin) { create(:user, :admin) }
  let(:profile) { create(:organizer_profile, :verified) }
  let(:organization) { profile.organization }
  let(:event) { create(:event, :completed, organization: organization, organizer_profile: profile) }
  let(:ticket_type) { create(:ticket_type, event: event, price_cents: 2000) }

  before do
    allow(StripeService).to receive(:verify_payment_context!)
    allow(StripeProcessingFees).to receive(:require_adjustment_review!)
    allow(Sentry).to receive(:capture_message)
    allow(Sentry).to receive(:capture_exception)
    approved_bank_account!(organization, actor: profile.user, admin: admin)
  end

  def classified!
    classified_capture(items: [[1200, 160, 0, 0]], event: event).then do |classified, payment, _capture|
      component = create(:fee_component, order: classified, order_item: classified.order_items.first, kind: "processing",
        amount_cents: 69, estimated: false, provider_reference: "txn_acc_#{SecureRandom.hex(4)}")
      create(:stripe_fee_evidence, :verified, payment: payment, fee_component: component,
        provider_balance_transaction_id: component.provider_reference)
    end
  end

  def reconcile!(payout, status, **evidence)
    patch "/api/v1/admin/payouts/#{payout.id}", headers: auth_headers(admin), as: :json,
      params: { status: status, provider_payout_id: payout.provider_payout_id,
        evidence: { reference: "Bank transfer record", reason: "Bank confirms the transfer", confirmed_at: Time.current.utc.iso8601(6),
          approved_tax_payee_confirmed: true, **evidence } }
  end

  def fresh_payout!(key)
    PayoutCreator.call(settlement: Settlements::Finalizer.call(event: event, actor: admin), actor: admin,
      idempotency_key: key, amount_cents: 1000)
  end

  def cpa
    now = Time.current.in_time_zone("Pacific/Guam")
    CpaMonthlyReport.new(now.year, now.month).report
  end

  it "keeps the provider's acceptance, never resends, pays, fails or frees it, and books it once" do
    order, item, capture = record_card_sale!(event, ticket_type: ticket_type, quantity: 5)
    classified!
    settlement = Settlements::Finalizer.call(event: event, actor: admin)
    calls = 0
    allow(PayoutGateway).to receive(:submit) do |_payout|
      calls += 1
      # After the submission authorization, before the provider's answer.
      record_card_refund!(order, item, capture, proceeds_cents: 500)
      PayoutGateway::Result.new(provider_payout_id: "BANK-ACCEPT-1", status: :paid)
    end

    payout = PayoutCreator.call(settlement: settlement, actor: admin, idempotency_key: "accept-1", amount_cents: 1000)
    expect(payout.reload).to have_attributes(status: "processing", provider_payout_id: "BANK-ACCEPT-1",
      failure_code: "provider_result_conflict", paid_at: nil, amount_cents: 1000)
    expect(PayoutCustodyDetermination.where(payout: payout)).to be_empty
    conflict = AuditLog.where(auditable: payout, action: "payout.provider_result_conflict").sole
    expect(conflict.metadata).to include("conflict_reason" => PayoutCreator::PAID_REFUSED_REASON,
      "entry_blocker" => "statement_changed", "amount_cents" => 1000, "disbursement_cents" => payout.disbursement_cents,
      "provider_result" => include("status" => "paid", "provider_payout_id" => "BANK-ACCEPT-1"))
    expect(Time.iso8601(conflict.metadata["provider_paid_at"])).to be_within(5.seconds).of(Time.current)
    expect(AuditLog.where(auditable: payout, action: "payout.paid")).to be_empty

    # No resend under the same key; no new money under a fresh one.
    expect(PayoutCreator.call(settlement: settlement, actor: admin, idempotency_key: "accept-1", amount_cents: 1000)).to eq(payout)
    expect { fresh_payout!("accept-2") }.to raise_error(PayoutCreator::PayoutError, /available balance/)
    expect(calls).to eq(1)

    # A later provider result never downgrades it.
    PayoutCreator.new(settlement: settlement, actor: admin, idempotency_key: "accept-1")
      .send(:record_submission_outcome!, payout, status: :failed, provider_payout_id: "BANK-ACCEPT-1",
        failure_code: "provider_returned", initiated_at: Time.current)
    expect(payout.reload).to have_attributes(status: "processing", provider_payout_id: "BANK-ACCEPT-1")
    expect(AuditLog.where(auditable: payout, action: "payout.late_result_ignored").sole.metadata)
      .to include("accepted_transfer" => true)

    # Never ordinary paid, even with a sent-before confirmation.
    reconcile!(payout, "paid", conflict_audit_id: conflict.id, sent_before_restatement_confirmed: true)
    expect(response).to have_http_status(:unprocessable_content)
    expect(response.parsed_body["error"]).to eq(PayoutReconciler::ACCEPTED_NOT_PAID_MESSAGE)

    # Finance verifies the acceptance (authenticated, audited).
    patch "/api/v1/admin/payouts/#{payout.id}", headers: auth_headers(create(:user)), as: :json,
      params: { status: "accepted_transfer", evidence: { reference: "Bank", reason: "Not an admin", confirmed_at: Time.current.utc.iso8601(6) } }
    expect(response).to have_http_status(:forbidden)
    reconcile!(payout, "accepted_transfer", conflict_audit_id: conflict.id)
    expect(response).to have_http_status(:ok)
    expect(payout.reload).to have_attributes(status: "processing", failure_message: PayoutReconciler::ACCEPTED_TRANSFER_MESSAGE)
    accepted = AuditLog.where(auditable: payout, action: "payout.accepted_transfer_recorded").sole
    expect(accepted.actor_user).to eq(admin)

    get "/api/v1/admin/payouts", headers: auth_headers(admin)
    listing = response.parsed_body["payouts"].find { |row| row["id"] == payout.id }
    expect(listing).to include("provider_accepted" => true, "allowed_outcomes" => ["reversed"])

    # Cash out exactly once, with its identity.
    report = cpa
    expect(report[:accepted_transfers]).to eq([{ payout_id: payout.id, organization_id: organization.id, event_id: event.id,
      provider: "manual", provider_payout_id: "BANK-ACCEPT-1", amount_cents: 1000,
      recorded_at: accepted.created_at.utc.iso8601(6) }])
    row = report[:rows].find { |entry| entry[:event_id] == event.id }
    expect(row).to include(organizer_payouts_made_cents: 1000, payout_reversals_cents: 0)

    # Failure or reversal without the exact return keeps the reservation.
    reconcile!(payout, "failed", conflict_audit_id: conflict.id)
    expect(response.parsed_body["error"]).to eq(PayoutReconciler::ACCEPTED_NOT_FAILED_MESSAGE)
    reconcile!(payout, "reversed", conflict_audit_id: conflict.id)
    expect(response.parsed_body["error"]).to match(/only with the bank's return evidence/)
    returned = { return_reference: "RET-0001", returned_amount_cents: payout.disbursement_cents - 1,
      returned_at: Time.current.utc.iso8601(6) }
    reconcile!(payout, "reversed", conflict_audit_id: conflict.id, **returned)
    expect(response.parsed_body["error"]).to match(/full #{payout.disbursement_cents} cents/)
    reconcile!(payout, "reversed", conflict_audit_id: conflict.id, **returned,
      returned_amount_cents: payout.disbursement_cents, returned_at: (conflict.occurred_at - 1.minute).utc.iso8601(6))
    expect(response.parsed_body["error"]).to match(/after the provider accepted/)
    expect(payout.reload).to be_status_processing
    expect { fresh_payout!("accept-3") }.to raise_error(PayoutCreator::PayoutError, /available balance/)
    expect(calls).to eq(1)

    # The exact return frees it, once, and books the reversal.
    reconcile!(payout, "reversed", conflict_audit_id: conflict.id, **returned, returned_amount_cents: payout.disbursement_cents)
    expect(response).to have_http_status(:ok)
    expect(payout.reload).to have_attributes(status: "reversed", provider_payout_id: "BANK-ACCEPT-1", paid_at: nil)
    reversal = AuditLog.where(auditable: payout, action: "payout.reconciled").sole
    expect(reversal.metadata["accepted_transfer_return"]).to include("return_reference" => "RET-0001",
      "returned_amount_cents" => payout.disbursement_cents, "accepted_at" => conflict.occurred_at.utc.iso8601(6))
    report = cpa
    expect(report[:accepted_transfers].map { |entry| entry[:payout_id] }).to eq([payout.id])
    expect(report[:rows].find { |entry| entry[:event_id] == event.id })
      .to include(organizer_payouts_made_cents: 1000, payout_reversals_cents: 1000)
    expect(report[:current_integrity_alerts][:missing_reversal_audit_payouts]).to be_empty

    allow(PayoutGateway).to receive(:submit) { |next_payout| PayoutGateway::Result.new(provider_payout_id: "manual_po_#{next_payout.id}", status: :processing) }
    expect(fresh_payout!("accept-4")).to be_status_processing
  end

  # A2 recheck finding 2 (7664e143): the bank's return arrives before finance
  # acknowledged the acceptance. The return waits for the acceptance record,
  # so CPA books the outgoing transfer and its return, each exactly once,
  # however often either step is retried. The database refuses the reverse
  # order for any writer.
  it "records the acceptance before an early return, so both CPA postings exist once across retries" do
    order, item, capture = record_card_sale!(event, ticket_type: ticket_type, quantity: 5)
    classified!
    settlement = Settlements::Finalizer.call(event: event, actor: admin)
    allow(PayoutGateway).to receive(:submit) do |_payout|
      record_card_refund!(order, item, capture, proceeds_cents: 500)
      PayoutGateway::Result.new(provider_payout_id: "BANK-EARLY-1", status: :paid)
    end
    payout = PayoutCreator.call(settlement: settlement, actor: admin, idempotency_key: "early-1", amount_cents: 1000)
    conflict = AuditLog.where(auditable: payout, action: "payout.provider_result_conflict").sole
    returned = { conflict_audit_id: conflict.id, return_reference: "RET-EARLY-1",
      returned_amount_cents: payout.reload.disbursement_cents, returned_at: Time.current.utc.iso8601(6) }

    # The return first: refused with the order to follow, nothing changes.
    reconcile!(payout, "reversed", **returned)
    expect(response).to have_http_status(:unprocessable_content)
    expect(response.parsed_body["error"]).to eq(PayoutReconciler::ACCEPTED_RETURN_BEFORE_ACCEPTANCE_MESSAGE)
    expect(payout.reload).to have_attributes(status: "processing", failure_code: "provider_result_conflict")
    expect(AuditLog.where(auditable: payout, action: %w[payout.reconciled payout.accepted_transfer_recorded])).to be_empty
    expect(cpa[:accepted_transfers]).to be_empty

    # Raw SQL in the same order is refused at commit, even with the exact
    # return recorded.
    expect do
      ActiveRecord::Base.transaction(requires_new: true) do
        Payout.where(id: payout.id).update_all(status: Payout.statuses[:reversed])
        AuditLog.create!(auditable: payout, organization: organization, action: "payout.reconciled", occurred_at: Time.current,
          before_data: { "status" => "processing" }, after_data: { "status" => "reversed" },
          metadata: { "accepted_transfer_return" => returned.except(:conflict_audit_id).stringify_keys })
        ActiveRecord::Base.connection.execute("SET CONSTRAINTS payouts_reversal_return_check IMMEDIATE")
      end
    end.to raise_error(ActiveRecord::StatementInvalid, /record the accepted transfer before its return/)
    expect(payout.reload).to be_status_processing

    # Acceptance, retried; then the return, retried (same evidence each time).
    confirmed_at = Time.current.utc.iso8601(6)
    2.times do
      reconcile!(payout, "accepted_transfer", conflict_audit_id: conflict.id, confirmed_at: confirmed_at)
      expect(response).to have_http_status(:ok)
    end
    2.times do
      reconcile!(payout, "reversed", **returned, confirmed_at: confirmed_at)
      expect(response).to have_http_status(:ok)
    end
    expect { ActiveRecord::Base.connection.execute("SET CONSTRAINTS payouts_reversal_return_check IMMEDIATE") }.not_to raise_error
    expect(payout.reload).to have_attributes(status: "reversed", paid_at: nil)
    accepted = AuditLog.where(auditable: payout, action: "payout.accepted_transfer_recorded").sole
    reversal = AuditLog.where(auditable: payout, action: "payout.reconciled").sole
    expect([accepted.actor_user, reversal.actor_user]).to eq([admin, admin])
    expect(accepted.id).to be < reversal.id
    expect(reversal.metadata["accepted_transfer_return"]).to include("return_reference" => "RET-EARLY-1",
      "returned_amount_cents" => payout.disbursement_cents)

    # The saved CPA month: cash out once, its return once, in the row, the
    # totals and the authenticated CSV export.
    report = cpa
    expect(report[:accepted_transfers].map { |entry| entry[:payout_id] }).to eq([payout.id])
    expect(report[:rows].find { |entry| entry[:event_id] == event.id })
      .to include(organizer_payouts_made_cents: 1000, payout_reversals_cents: 1000)
    expect(report[:totals]).to include(organizer_payouts_made_cents: 1000, payout_reversals_cents: 1000)
    expect(report[:current_integrity_alerts][:missing_reversal_audit_payouts]).to be_empty
    now = Time.current.in_time_zone("Pacific/Guam")
    get "/api/v1/admin/tax_reports/cpa_monthly_export", headers: auth_headers(admin), params: { year: now.year, month: now.month }
    expect(response).to have_http_status(:ok)
    rows = CSV.parse(response.body, headers: true)
    total = rows.find { |row| row["row_type"] == "total" }
    expect(total.to_h.values_at("organizer_payouts_made", "payout_reversals")).to eq(%w[10.00 10.00])
    expect(rows.find { |row| row["event_id"] == event.id.to_s }.to_h.values_at("organizer_payouts_made", "payout_reversals"))
      .to eq(%w[10.00 10.00])
  end

  it "refuses return evidence on an outcome that is not a reversal" do
    record_card_sale!(event, ticket_type: ticket_type, quantity: 2)
    allow(PayoutGateway).to receive(:submit) { |payout| PayoutGateway::Result.new(provider_payout_id: "manual_po_#{payout.id}", status: :processing) }
    payout = fresh_payout!("ordinary-return")
    reconcile!(payout, "failed", reason: "Never sent", return_reference: "RET-2", returned_amount_cents: 1000,
      returned_at: Time.current.utc.iso8601(6))
    expect(response.parsed_body["error"]).to eq("Return evidence only applies to a reversal")
    reconcile!(payout, "failed", reason: "Never sent")
    expect(response).to have_http_status(:ok)
  end
end
