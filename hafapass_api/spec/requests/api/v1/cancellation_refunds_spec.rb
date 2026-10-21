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
end
