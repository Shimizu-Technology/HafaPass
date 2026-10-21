require "rails_helper"

RSpec.describe "Cancellation refund permissions", type: :request do
  let(:profile) { create(:organizer_profile, :verified) }
  let(:event) { create(:event, :published, organizer_profile: profile) }
  let(:base) { "/api/v1/organizer/events/#{event.id}" }

  it "requires the reviewed totals, permits the organizer, and rejects another organizer" do
    post "#{base}/cancel", params: { reason: "Storm" }, headers: auth_headers(profile.user)
    expect(response).to have_http_status(:conflict)
    post "#{base}/cancel", params: { reason: "Storm", refund_count: 0, refund_total_cents: 0 },
      headers: auth_headers(profile.user)
    expect(response).to have_http_status(:ok)
    expect(event.reload).to be_cancelled
    expect(event.event_cancellation_refund_run).to be_present
    other = create(:user, :organizer)
    get "#{base}/cancellation_refunds", headers: auth_headers(other)
    expect(response).to have_http_status(:forbidden)
  end

  it "rejects stale confirmation totals without cancelling" do
    post "#{base}/cancel", params: { reason: "Storm", refund_count: 1, refund_total_cents: 5250 },
      headers: auth_headers(profile.user)
    expect(response).to have_http_status(:conflict)
    expect(event.reload).to be_published
  end

  it "gives an admin the same progress view and refuses a non-admin" do
    get "/api/v1/admin/events/#{event.id}/cancellation_refunds", headers: auth_headers(create(:user, :admin))
    expect(response).to have_http_status(:ok)
    expect(response.parsed_body.fetch("preview")).to include("count" => 0)
    get "/api/v1/admin/events/#{event.id}/cancellation_refunds", headers: auth_headers(profile.user)
    expect(response).to have_http_status(:forbidden)
  end

  it "allows an admin to cancel with a reviewed refund total" do
    admin = create(:user, :admin)
    post "/api/v1/admin/events/#{event.id}/cancel_and_refund",
      params: { reason: "Storm", refund_count: 0, refund_total_cents: 0 }, headers: auth_headers(admin)

    expect(response).to have_http_status(:accepted)
    expect(event.reload).to be_cancelled
    expect(event.event_cancellation_refund_run.started_by).to eq(admin)
  end

  it "records an organizer cash return with evidence and an audit entry" do
    order = create(:order, event: event, payment_method: "door_cash")
    type = create(:ticket_type, event: event)
    create(:order_item, order: order, ticket_type: type, quantity: 2, subtotal_cents: 5000,
      fee_cents: 250, organizer_proceeds_cents: 5000)
    create(:payment, :succeeded, order: order, provider: "door_cash", provider_payment_id: "cash_test")
    EventLifecycle.call(event: event, action: :cancel, actor: profile.user, reason: "Storm")
    EventCancellationRefundJob.perform_now(event.event_cancellation_refund_run.id)

    post "#{base}/cancellation_refunds/#{order.id}/mark_cash_refunded",
      params: { reference: "Cash receipt 27", returned_at: Time.current.iso8601(6) },
      headers: auth_headers(profile.user)
    expect(response).to have_http_status(:ok)
    expect(order.reload).to be_refunded
    expect(AuditLog.where(action: "event.cancellation_cash_refunded", auditable: event)).to exist
  end

  it "denies a manager cancellation, retry, and cash return while allowing a progress view" do
    manager = create(:user)
    create(:organization_membership, organization: event.organization, user: manager, role: :manager)
    get "#{base}/cancellation_refunds", headers: auth_headers(manager)
    expect(response).to have_http_status(:ok)
    post "#{base}/cancel", params: { reason: "Storm", refund_count: 0, refund_total_cents: 0 },
      headers: auth_headers(manager)
    expect(response).to have_http_status(:forbidden)
    expect(event.reload).to be_published

    EventLifecycle.call(event: event, action: :cancel, actor: profile.user, reason: "Storm")
    post "#{base}/retry_cancellation_refunds", headers: auth_headers(manager)
    expect(response).to have_http_status(:forbidden)
    post "#{base}/cancellation_refunds/123/mark_cash_refunded",
      params: { reference: "receipt", returned_at: Time.current.iso8601 }, headers: auth_headers(manager)
    expect(response).to have_http_status(:forbidden)
  end

  it "advances the key for a terminal failed provider refund with an ID" do
    order = create(:order, event: event)
    type = create(:ticket_type, event: event)
    create(:order_item, order: order, ticket_type: type, quantity: 2, subtotal_cents: 5000,
      fee_cents: 250, organizer_proceeds_cents: 5000)
    payment = create(:payment, :succeeded, order: order, provider: "stripe", provider_payment_id: "sim_pi_retry")
    EventLifecycle.call(event: event, action: :cancel, actor: profile.user, reason: "Storm")
    item = event.event_cancellation_refund_run.items.find_by!(order: order)
    create(:refund, order: order, payment: payment, amount_cents: item.amount_cents, status: :failed,
      succeeded_at: nil, provider_refund_id: "re_failed_with_id", idempotency_key: item.refund_key)
    item.update!(status: :failed)
    post "#{base}/retry_cancellation_refunds", headers: auth_headers(profile.user)
    expect(response).to have_http_status(:accepted)
    expect(item.reload.retry_generation).to eq(1)
    expect(item).to be_pending
  end

  it "retains the key for an uncertain pending provider result" do
    order = create(:order, event: event)
    type = create(:ticket_type, event: event)
    create(:order_item, order: order, ticket_type: type, quantity: 2, subtotal_cents: 5000,
      fee_cents: 250, organizer_proceeds_cents: 5000)
    payment = create(:payment, :succeeded, order: order, provider: "stripe", provider_payment_id: "sim_pi_unknown")
    EventLifecycle.call(event: event, action: :cancel, actor: profile.user, reason: "Storm")
    item = event.event_cancellation_refund_run.items.find_by!(order: order)
    create(:refund, order: order, payment: payment, amount_cents: item.amount_cents, status: :pending,
      succeeded_at: nil, provider_refund_id: nil, failure_code: "provider_result_unknown",
      idempotency_key: item.refund_key)
    item.update!(status: :failed)
    post "#{base}/retry_cancellation_refunds", headers: auth_headers(profile.user)
    expect(response).to have_http_status(:accepted)
    expect(item.reload.retry_generation).to eq(0)
    expect(item).to be_pending
  end
end
