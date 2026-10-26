require "rails_helper"

RSpec.describe "Refund reconciliation", type: :request do
  let(:admin) { create(:user, :admin) }
  let(:profile) { create(:organizer_profile) }
  let(:event) { create(:event, :published, organizer_profile: profile) }

  def payment_for(order, provider: "stripe")
    create(:payment, :succeeded, order: order, provider: provider,
      provider_environment: "live")
  end

  def pending_refund(event: self.event, status: :pending)
    order = create(:order, event: event)
    type = create(:ticket_type, event: event)
    create(:order_item, order: order, ticket_type: type, quantity: 2,
      subtotal_cents: 5000, fee_cents: 250, organizer_proceeds_cents: 5000)
    payment = payment_for(order)
    create(:refund, order: order, payment: payment, status: status, succeeded_at: nil,
      failed_at: status == :failed ? 4.days.ago : nil, created_at: 4.days.ago,
      provider_refund_id: status == :pending ? "re_pending_#{order.id}" : nil)
  end

  def cash_item
    event.update!(status: :cancelled)
    order = create(:order, event: event, payment_method: "door_cash")
    type = create(:ticket_type, event: event)
    create(:order_item, order: order, ticket_type: type, quantity: 2,
      subtotal_cents: 5000, fee_cents: 250, organizer_proceeds_cents: 5000)
    payment_for(order, provider: "door_cash")
    run = event.create_event_cancellation_refund_run!(started_by: admin)
    run.items.create!(order: order, status: :needs_manual, amount_cents: 5250)
  end

  it "exposes provider verification separately to admin and organizer and blocks another refund" do
    failed = pending_refund(status: :failed)
    order = failed.order
    payment = failed.payment
    create(:refund, order: order, payment: payment, status: :succeeded, amount_cents: 1000)
    issue = create(:reconciliation_exception, order: order, payment: payment,
      code: "refund_aggregate_requires_reconciliation", actual_amount_cents: 3000)
    allow(StripeService).to receive(:find_refund).and_return(nil)
    allow(StripeService).to receive(:refund_payment)

    [["admin", admin], ["organizer", profile.user]].each do |role, actor|
      get "/api/v1/#{role}/refund_reconciliation", params: { event_id: event.id }, headers: auth_headers(actor)
      expect(response).to have_http_status(:ok), response.body
      rows = response.parsed_body.fetch("items")
      expect(rows.find { |row| row["type"] == "exception" }).to include(
        "id" => issue.id, "amount_cents" => 0, "buyer_amount_cents" => nil, "provider_amount_kind" => "aggregate",
        "provider_reported_amount_cents" => 3000, "provider_verification_amount_cents" => 2000,
        "buyer_amount_unverified" => true)
      expect(rows.find { |row| row["type"] == "refund" }).to include("buyer_amount_unverified" => true)
    end
    expect do
      post "/api/v1/admin/refund_reconciliation/refund/#{failed.id}/retry", headers: auth_headers(admin)
    end.not_to change(Refund, :count)
    expect(response).to have_http_status(:unprocessable_content)
    expect(response.parsed_body.fetch("error")).to match(/finance review/)
    expect(StripeService).not_to have_received(:refund_payment)
    expect(issue.reload).to be_open
    expect(OrganizationPayoutBalance.available_cents(event.organization)).to eq(0)
    create(:payout, event: event, organization: event.organization, status: :held,
      held_from_status: "pending", with_tax_snapshot: false)
    get "/api/v1/admin/payouts", headers: auth_headers(admin)
    expect(response).to have_http_status(:ok), response.body
    expect(response.parsed_body.fetch("payouts").size).to eq(1)
  end

  it "verifies a failed historical operation without sending money or clearing other payout holds" do
    failed = pending_refund(status: :failed)
    order = failed.order
    payment = failed.payment
    issue = create(:reconciliation_exception, order: order, payment: payment,
      code: "refund_operation_not_found", details: { provider_refund_id: "re_history_queue",
        provider_payment_id: payment.provider_payment_id, amount_cents: 1200, currency: "usd", status: "failed" })
    other = create(:reconciliation_exception, order: order, payment: payment, code: "fee_review")
    allow(StripeService).to receive(:list_refunds).and_return([OpenStruct.new(id: "re_history_queue",
      payment_intent: payment.provider_payment_id, amount: 1200, currency: "usd", status: "failed")])
    allow(StripeService).to receive(:refund_payment)
    2.times do
      post "/api/v1/admin/refund_reconciliation/exception/#{issue.id}/resync", headers: auth_headers(admin)
      expect(response).to have_http_status(:ok), response.body
    end
    expect(issue.reload).to be_resolved
    expect(other.reload).to be_open
    expect(order.refunds.succeeded).to be_empty
    expect(order.refunds.where(provider_refund_id: "re_history_queue").count).to eq(1)
    expect(order.refundable_cents).to eq(5250)
    expect(StripeService).not_to have_received(:refund_payment)
    expect(OrganizationPayoutBalance.available_cents(event.organization)).to eq(0)
    get "/api/v1/admin/refund_reconciliation", params: { event_id: event.id }, headers: auth_headers(admin)
    expect(response.parsed_body.fetch("items")).to contain_exactly(include("type" => "refund", "id" => failed.id,
      "buyer_amount_unverified" => false))
  end

  it "keeps separate administrators' pending resync observations" do
    refund = pending_refund
    other_admin = create(:user, :admin)
    allow(StripeService).to receive(:retrieve_refund).and_return(OpenStruct.new(
      id: refund.provider_refund_id, status: "pending", amount: refund.amount_cents, currency: "usd"))
    [admin, other_admin].each do |operator|
      post "/api/v1/admin/refund_reconciliation/refund/#{refund.id}/resync", headers: auth_headers(operator)
      expect(response).to have_http_status(:ok), response.body
    end
    rows = AuditLog.where(action: "refund_reconciliation.resynced", auditable: refund).order(:id)
    expect(rows.map(&:actor_user_id)).to eq([admin.id, other_admin.id])
    expect(rows.map(&:request_id).uniq.length).to eq(2)
  end

  it "cannot mutate another organization's cancellation item from the selected organization" do
    item = cash_item
    other = create(:organization)
    create(:organization_membership, organization: other, user: profile.user, role: :owner)
    path = "/api/v1/organizer/refund_reconciliation/cancellation/#{item.id}/manual_return"
    expect do
      post path, params: { reference: "LOCAL-ONLY", returned_at: Time.current.iso8601(6), note: "Local cash return evidence" },
        headers: auth_headers(profile.user).merge("X-Organization-Id" => other.id.to_s)
    end.not_to change(Refund, :count)
    expect(response).to have_http_status(:not_found)
    expect(item.reload).to be_needs_manual
    post path, params: { reference: "LOCAL-ONLY", returned_at: Time.current.iso8601(6), note: "Local cash return evidence" },
      headers: auth_headers(profile.user).merge("X-Organization-Id" => event.organization_id.to_s)
    expect(response).to have_http_status(:ok), response.body
    expect(item.reload).to be_refunded
  end

  it "lists only unresolved items for an organizer's organization and filters the admin list" do
    mine = pending_refund
    another = pending_refund(event: create(:event, :published))

    get "/api/v1/organizer/refund_reconciliation", headers: auth_headers(profile.user)
    expect(response).to have_http_status(:ok), response.body
    expect(response.parsed_body.fetch("items").map { |item| item.fetch("id") }).to include(mine.id)
    expect(response.parsed_body.fetch("items").map { |item| item.fetch("id") }).not_to include(another.id)

    get "/api/v1/admin/refund_reconciliation", params: { event_id: event.id, status: "pending", age_days: 3 },
      headers: auth_headers(admin)
    expect(response).to have_http_status(:ok), response.body
    expect(response.parsed_body.fetch("items").map { |item| item.fetch("id") }).to eq([mine.id])
    expect(response.parsed_body.fetch("meta")).to include("total" => 1)
  end

  it "rejects non-admin access to the admin queue and actions" do
    refund = pending_refund(status: :failed)
    get "/api/v1/admin/refund_reconciliation", headers: auth_headers(profile.user)
    expect(response).to have_http_status(:forbidden)
    post "/api/v1/admin/refund_reconciliation/refund/#{refund.id}/retry", headers: auth_headers(profile.user)
    expect(response).to have_http_status(:forbidden)
    expect(refund.reload).to be_failed
  end

  it "retries a failed Stripe refund through RefundCreator once and keeps the failed attempt" do
    failed = pending_refund(status: :failed)
    allow(StripeService).to receive(:find_refund).and_return(nil)
    allow(StripeService).to receive(:refund_payment).and_return(OpenStruct.new(
      id: "re_retry_#{failed.id}", status: "succeeded", amount: failed.amount_cents, currency: "usd"))

    path = "/api/v1/admin/refund_reconciliation/refund/#{failed.id}/retry"
    post path, headers: auth_headers(admin)
    expect(response).to have_http_status(:ok), response.body
    expect(failed.reload).to be_failed
    expect(failed.order.refunds.succeeded.sum(:amount_cents)).to eq(failed.amount_cents)
    expect(AuditLog.where(action: "refund_reconciliation.retry", actor_user: admin)).to exist

    expect { post path, headers: auth_headers(admin) }.not_to change(Refund, :count)
    expect(failed.order.refunds.succeeded.sum(:amount_cents)).to eq(failed.amount_cents)
    expect(StripeService).to have_received(:refund_payment).once
  end

  it "audits a retry attempt even when the Stripe result is unknown" do
    failed = pending_refund(status: :failed)
    allow(StripeService).to receive(:find_refund).and_return(nil)
    allow(StripeService).to receive(:refund_payment).and_raise(Timeout::Error)

    post "/api/v1/admin/refund_reconciliation/refund/#{failed.id}/retry", headers: auth_headers(admin)

    expect(response).to have_http_status(:unprocessable_content)
    expect(AuditLog.where(action: "refund_reconciliation.action_attempted", auditable: failed,
      actor_user: admin)).to exist
    expect(AuditLog.where(action: "refund_reconciliation.retry", auditable: failed)).not_to exist
    expect(failed.order.refunds.pending.find_by(idempotency_key: "refund-reconciliation/#{failed.id}")
      .failure_code).to eq("provider_result_unknown")
  end

  it "executes an unfulfilled buyer request once through RefundCreator" do
    order = create(:order, event: event)
    ticket_type = create(:ticket_type, event: event)
    item = create(:order_item, order: order, ticket_type: ticket_type, quantity: 1, unit_price_cents: 5000,
      subtotal_cents: 5000, fee_cents: 250, organizer_proceeds_cents: 5000)
    create(:ticket, order: order, order_item: item, event: event, ticket_type: ticket_type)
    payment_for(order)
    change = event.event_changes.create!(change_type: "rescheduled", occurred_at: 1.day.ago)
    request = change.event_change_responses.create!(order: order, decision: "refund_requested", responded_at: 1.day.ago)
    allow(StripeService).to receive(:refund_payment).and_return(OpenStruct.new(
      id: "re_request_#{request.id}", status: "succeeded", amount: order.total_cents, currency: "usd"))
    path = "/api/v1/admin/refund_reconciliation/request/#{request.id}/retry"

    post path, headers: auth_headers(admin)
    expect(response).to have_http_status(:ok), response.body
    expect(order.refunds.succeeded.sole).to have_attributes(amount_cents: order.total_cents,
      reason: "event_change_refund")
    expect(AuditLog.where(action: "refund_reconciliation.request_executed", auditable: request)).to exist
    post path, headers: auth_headers(admin)
    expect(response).to have_http_status(:unprocessable_content)
    expect(order.refunds.count).to eq(1)
    expect(StripeService).to have_received(:refund_payment).once
  end

  it "re-syncs a pending Stripe refund and audits the provider result" do
    refund = pending_refund
    allow(StripeService).to receive(:retrieve_refund).and_return(OpenStruct.new(
      id: refund.provider_refund_id, status: "succeeded", amount: refund.amount_cents, currency: "usd"))

    post "/api/v1/admin/refund_reconciliation/refund/#{refund.id}/resync", headers: auth_headers(admin)

    expect(response).to have_http_status(:ok), response.body
    expect(refund.reload).to be_succeeded
    expect(AuditLog.where(action: "refund_reconciliation.resynced", actor_user: admin)).to exist
    post "/api/v1/admin/refund_reconciliation/refund/#{refund.id}/resync", headers: auth_headers(admin)
    expect(response).to have_http_status(:unprocessable_content)
    expect(StripeService).to have_received(:retrieve_refund).once
  end

  it "keeps an ambiguous missing-ID lookup open and flags it for manual review" do
    refund = pending_refund
    refund.update!(provider_refund_id: nil)
    allow(StripeService).to receive(:find_refund).and_raise(StripeService::AmbiguousRefund.new("Multiple matches; manual review"))

    post "/api/v1/admin/refund_reconciliation/refund/#{refund.id}/resync", headers: auth_headers(admin)

    expect(response).to have_http_status(:unprocessable_content)
    expect(refund.reload).to be_pending
    expect(RefundReconciliationQueue.call.fetch(:items)).to include(include(
      id: refund.id, unable_reason: "Provider refund lookup is ambiguous; manual finance review is required"))
    expect(AuditLog.where(action: "refund_reconciliation.unable", auditable: refund).sole.metadata)
      .not_to have_value("Multiple matches; manual review")
  end

  it "does not retry a failed refund when Stripe says the earlier transfer succeeded" do
    failed = pending_refund(status: :failed)
    allow(StripeService).to receive(:find_refund).and_return(OpenStruct.new(
      id: "re_already_sent", status: "succeeded", amount: failed.amount_cents, currency: "usd"))
    allow(StripeService).to receive(:refund_payment)

    expect do
      post "/api/v1/admin/refund_reconciliation/refund/#{failed.id}/retry", headers: auth_headers(admin)
    end.not_to change(Refund, :count)
    expect(response).to have_http_status(:unprocessable_content)
    expect(StripeService).not_to have_received(:refund_payment)
    expect(ReconciliationException.where(order: failed.order, code: "refund_terminal_status_conflict")).to exist
  end

  it "queues one cancellation retry after a known failed Stripe attempt" do
    event.update!(status: :cancelled)
    order = create(:order, event: event)
    type = create(:ticket_type, event: event)
    create(:order_item, order: order, ticket_type: type, quantity: 2,
      subtotal_cents: 5000, fee_cents: 250, organizer_proceeds_cents: 5000)
    payment = payment_for(order)
    run = event.create_event_cancellation_refund_run!(started_by: admin)
    item = run.items.create!(order: order, status: :failed, amount_cents: 5250)
    create(:refund, order: order, payment: payment, status: :failed, amount_cents: 5250,
      idempotency_key: item.refund_key, provider_refund_id: nil, failure_code: "provider_error")

    queued_before = enqueued_jobs.count { |job| job[:job] == EventCancellationRefundJob && job[:args] == [run.id] }
    post "/api/v1/organizer/refund_reconciliation/cancellation/#{item.id}/retry", headers: auth_headers(profile.user)
    expect(response).to have_http_status(:ok), response.body
    expect(enqueued_jobs.count { |job| job[:job] == EventCancellationRefundJob && job[:args] == [run.id] } - queued_before).to eq(1)
    expect(item.reload).to be_pending
    expect(item.retry_generation).to eq(1)
    expect(AuditLog.where(action: "refund_reconciliation.cancellation_retry", auditable: item)).to exist
  end

  it "requires complete evidence for a cash return, then records the return and audit" do
    item = cash_item
    path = "/api/v1/organizer/refund_reconciliation/cancellation/#{item.id}/manual_return"
    evidence = { reference: "Cash receipt 42", returned_at: Time.current.iso8601(6), note: "Returned at the box office" }

    post path, params: evidence.except(:note), headers: auth_headers(profile.user)
    expect(response).to have_http_status(:unprocessable_content)
    expect(item.reload).to be_needs_manual

    post path, params: evidence, headers: auth_headers(profile.user)
    expect(response).to have_http_status(:ok)
    expect(item.reload).to be_refunded
    expect(item.order.refunds.succeeded.sum(:amount_cents)).to eq(5250)
    audit = AuditLog.find_by!(action: "refund_reconciliation.manual_return", actor_user: profile.user)
    expect(audit.metadata.to_json).to include("Returned at the box office")
  end

  it "restricts non-Stripe card return recording to an administrator" do
    event.update!(status: :cancelled)
    order = create(:order, event: event, payment_method: "door_card")
    type = create(:ticket_type, event: event)
    create(:order_item, order: order, ticket_type: type, quantity: 2,
      subtotal_cents: 5000, fee_cents: 250, organizer_proceeds_cents: 5000)
    payment_for(order, provider: "boh_clover")
    run = event.create_event_cancellation_refund_run!(started_by: admin)
    item = run.items.create!(order: order, status: :needs_manual, amount_cents: 5250)
    path = "/api/v1/organizer/refund_reconciliation/cancellation/#{item.id}/manual_return"
    evidence = { reference: "Card receipt 71", returned_at: Time.current.iso8601(6), note: "Provider credit confirmed" }

    post path, params: evidence, headers: auth_headers(profile.user)
    expect(response).to have_http_status(:forbidden)
    expect(item.reload).to be_needs_manual
    post "/api/v1/admin/refund_reconciliation/cancellation/#{item.id}/manual_return",
      params: evidence, headers: auth_headers(admin)
    expect(response).to have_http_status(:ok), response.body
    expect(item.reload).to be_refunded
    expect(order.refunds.succeeded.first.provider_payload).to have_key("manual_card_return")
  end

  it "keeps an unable-to-refund obligation visible with a required reason" do
    refund = pending_refund(status: :failed)
    path = "/api/v1/admin/refund_reconciliation/refund/#{refund.id}/unable"
    post path, params: { reason: "" }, headers: auth_headers(admin)
    expect(response).to have_http_status(:unprocessable_content)

    post path, params: { reason: "Buyer cannot be reached after three attempts" }, headers: auth_headers(admin)
    expect(response).to have_http_status(:ok)
    get "/api/v1/admin/refund_reconciliation", headers: auth_headers(admin)
    row = response.parsed_body.fetch("items").find { |item| item["type"] == "refund" && item["id"] == refund.id }
    expect(row).to include("unable_reason" => "Buyer cannot be reached after three attempts")
    expect(refund.reload).to be_failed
    expect(AuditLog.where(action: "refund_reconciliation.unable", actor_user: admin)).to exist
  end

  it "does not grant organizer refund actions to a manager or another organization" do
    item = cash_item
    manager = create(:user)
    create(:organization_membership, organization: event.organization, user: manager, role: :manager)
    other_owner = create(:organizer_profile).user
    path = "/api/v1/organizer/refund_reconciliation/cancellation/#{item.id}/manual_return"
    evidence = { reference: "Cash receipt 42", returned_at: Time.current.iso8601(6), note: "Returned" }

    post path, params: evidence, headers: auth_headers(manager)
    expect(response).to have_http_status(:forbidden)
    post path, params: evidence, headers: auth_headers(other_owner)
    expect(response).to have_http_status(:forbidden).or have_http_status(:not_found)
    expect(item.reload).to be_needs_manual
  end
end
