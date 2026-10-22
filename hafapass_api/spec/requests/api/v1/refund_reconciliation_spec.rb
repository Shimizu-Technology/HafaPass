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
