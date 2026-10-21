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

  it "lets only an admin start an audited run for a legacy cancelled event" do
    legacy_event = create(:event, :cancelled, organizer_profile: profile)
    order = create(:order, event: legacy_event)
    create(:payment, :succeeded, order: order, provider_environment: "live")
    path = "/api/v1/admin/events/#{legacy_event.id}/start_cancellation_refunds"
    post path, headers: auth_headers(profile.user)
    expect(response).to have_http_status(:forbidden)
    expect(legacy_event.event_cancellation_refund_run).to be_nil

    admin = create(:user, :admin)
    post path, params: { refund_count: 0, refund_total_cents: 0 }, headers: auth_headers(admin)
    expect(response).to have_http_status(:conflict)
    expect(response.parsed_body.fetch("preview")).to include("count" => 1, "total_cents" => 5250)
    expect(legacy_event.event_cancellation_refund_run).to be_nil

    expect { post path, params: { refund_count: 1, refund_total_cents: 5250 }, headers: auth_headers(admin) }
      .to have_enqueued_job(EventCancellationRefundJob)
    expect(response).to have_http_status(:accepted)
    run = legacy_event.reload.event_cancellation_refund_run
    expect(run.started_by).to eq(admin)
    expect(run.items.find_by!(order: order).amount_cents).to eq(5250)
    expect(AuditLog.where(action: "event.legacy_cancellation_refunds_started", auditable: legacy_event)).to exist
    post path, params: { refund_count: 1, refund_total_cents: 5250 }, headers: auth_headers(admin)
    expect(response).to have_http_status(:conflict)
    expect(EventCancellationRefundRun.where(event: legacy_event).count).to eq(1)
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

  it "lets only an admin record an evidenced return for a captured non-Stripe card payment" do
    order = create(:order, event: event, payment_method: "door_card")
    type = create(:ticket_type, event: event)
    create(:order_item, order: order, ticket_type: type, quantity: 2, subtotal_cents: 5000,
      fee_cents: 250, organizer_proceeds_cents: 5000)
    create(:payment, :succeeded, order: order, provider: "boh_clover", provider_environment: "live",
      provider_payment_id: "clover_fixture_#{order.id}")
    EventLifecycle.call(event: event, action: :cancel, actor: profile.user, reason: "Storm")
    run = event.reload.event_cancellation_refund_run
    EventCancellationRefundJob.perform_now(run.id)
    expect(run.items.find_by!(order: order)).to be_needs_manual
    expect(OrderPresenter.call(order)[:cancellation_refund][:status]).to eq("needs_card_return")
    path = "/api/v1/admin/events/#{event.id}/cancellation_refunds/#{order.id}/mark_card_refunded"
    payload = { reference: "Clover return 42", returned_at: Time.current.iso8601(6) }

    post path, params: payload, headers: auth_headers(profile.user)
    expect(response).to have_http_status(:forbidden)
    post path, params: payload, headers: auth_headers(create(:user, :admin))
    expect(response).to have_http_status(:ok)
    expect(order.reload).to be_refunded
    expect(run.items.find_by!(order: order)).to be_refunded
    expect(order.refunds.succeeded.first.provider_payload["manual_card_return"]["reference"]).to eq("Clover return 42")
    expect(AuditLog.where(action: "event.cancellation_card_refunded", auditable: event)).to exist
  end

  it "shows and records the current cash balance after a separate partial return" do
    order = create(:order, event: event, payment_method: "door_cash")
    type = create(:ticket_type, event: event)
    order_item = create(:order_item, order: order, ticket_type: type, quantity: 2, subtotal_cents: 5000,
      fee_cents: 250, organizer_proceeds_cents: 5000)
    payment = create(:payment, :succeeded, order: order, provider: "door_cash", provider_payment_id: "cash_partial")
    EventLifecycle.call(event: event, action: :cancel, actor: profile.user, reason: "Storm")
    run = event.reload.event_cancellation_refund_run
    EventCancellationRefundJob.perform_now(run.id)
    item = run.items.find_by!(order: order)
    expect(item.amount_cents).to eq(5250)
    separate = create(:refund, order: order, payment: payment, provider: "door_cash", amount_cents: 500)
    create(:refund_item, refund: separate, order_item: order_item, amount_cents: 500,
      organizer_proceeds_cents: 500, fee_cents: 0)

    get "#{base}/cancellation_refunds", headers: auth_headers(profile.user)
    expect(response.parsed_body.dig("run", "items", 0, "amount_cents")).to eq(4750)
    expect(item.reload.amount_cents).to eq(4750)

    later = create(:refund, order: order, payment: payment, provider: "door_cash", amount_cents: 500)
    create(:refund_item, refund: later, order_item: order_item, amount_cents: 500,
      organizer_proceeds_cents: 500, fee_cents: 0)

    post "#{base}/cancellation_refunds/#{order.id}/mark_cash_refunded",
      params: { reference: "Cash receipt partial", returned_at: Time.current.iso8601(6) },
      headers: auth_headers(profile.user)
    expect(response).to have_http_status(:ok), response.body
    expect(item.reload.amount_cents).to eq(4250)
    expect(order.refunds.succeeded.sum(:amount_cents)).to eq(5250)
    expect(order.refunds.where(reason: "event_cancelled_cash_return").pick(:amount_cents)).to eq(4250)
  end

  it "resolves a manual item when a separate full cash return is recorded" do
    order = create(:order, event: event, payment_method: "door_cash")
    payment = create(:payment, :succeeded, order: order, provider: "door_cash", provider_payment_id: "cash_full")
    EventLifecycle.call(event: event, action: :cancel, actor: profile.user, reason: "Storm")
    run = event.reload.event_cancellation_refund_run
    EventCancellationRefundJob.perform_now(run.id)
    create(:refund, order: order, payment: payment, provider: "door_cash", amount_cents: 5250)

    get "#{base}/cancellation_refunds", headers: auth_headers(profile.user)
    item = run.items.find_by!(order: order)
    expect(item).to have_attributes(status: "skipped", amount_cents: 0)
    expect(run.reload).to be_completed
    expect(response.parsed_body.dig("run", "items", 0)).to include("status" => "skipped", "amount_cents" => 0)
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

  it "lets a manager preview with manage_events even without view_finance, but requires refund authority to cancel" do
    manager = create(:user)
    create(:organization_membership, organization: event.organization, user: manager, role: :manager)
    original = OrganizationAuthorization.method(:allowed?)
    allow(OrganizationAuthorization).to receive(:allowed?) do |**options|
      options[:permission] == :view_finance ? false : original.call(**options)
    end

    EventLifecycle.call(event: event, action: :cancel, actor: profile.user, reason: "Storm")
    get "#{base}/cancellation_refunds", headers: auth_headers(manager)
    expect(response).to have_http_status(:ok)
    expect(response.parsed_body.fetch("preview")).to include("total_cents" => 0)
    expect(response.parsed_body.fetch("run")).to be_nil
    post "#{base}/cancel", params: { reason: "Storm", refund_count: 0, refund_total_cents: 0 },
      headers: auth_headers(manager)
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

  it "retains the key for an uncertain failed provider result" do
    order = create(:order, event: event)
    type = create(:ticket_type, event: event)
    create(:order_item, order: order, ticket_type: type, quantity: 2, subtotal_cents: 5000,
      fee_cents: 250, organizer_proceeds_cents: 5000)
    payment = create(:payment, :succeeded, order: order, provider: "stripe", provider_payment_id: "sim_pi_failed_unknown")
    EventLifecycle.call(event: event, action: :cancel, actor: profile.user, reason: "Storm")
    item = event.event_cancellation_refund_run.items.find_by!(order: order)
    create(:refund, order: order, payment: payment, amount_cents: item.amount_cents, status: :failed,
      succeeded_at: nil, failure_code: "provider_result_unknown", idempotency_key: item.refund_key)
    item.update!(status: :failed)

    post "#{base}/retry_cancellation_refunds", headers: auth_headers(profile.user)
    expect(response).to have_http_status(:accepted)
    expect(item.reload.retry_generation).to eq(0)
  end
end
