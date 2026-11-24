# frozen_string_literal: true

require "rails_helper"
require "ostruct"

RSpec.describe "Online box office card sales", type: :request do
  include ActiveJob::TestHelper
  include ActiveSupport::Testing::TimeHelpers

  let(:profile) { create(:organizer_profile) }
  let(:organization) { profile.organization }
  let(:event) { create(:event, :published, organizer_profile: profile, online_door_card_enabled: true, max_capacity: 20) }
  let(:ticket_type) { create(:ticket_type, event: event, price_cents: 1200) }
  let(:staff) { create(:user) }
  let(:path) { "/api/v1/organizer/events/#{event.id}/box_office_card_sales" }
  let(:headers) { auth_headers(staff).merge("X-Organization-Id" => organization.id.to_s, "Idempotency-Key" => "box-office-#{SecureRandom.uuid}") }
  let(:signing_fixture) { "local-door-webhook-signing-fixture" }
  let(:cart) { { payment_method: "door_card_link", line_items: [{ ticket_type_id: ticket_type.id, quantity: 1 }] } }

  before do
    create(:organization_membership, organization: organization, user: staff, role: :box_office)
    create(:event_staff_assignment, event: event, user: staff, role: :box_office)
    SiteSetting.instance.update_columns(payment_mode: "test")
    allow(StripeService).to receive(:payment_enabled?).and_return(true)
    allow(StripeService).to receive(:platform_account_id).with("test").and_return("acct_DoorFixture")
    allow(StripeService).to receive(:verify_payment_context!).and_return(true)
    allow(StripeCredentials).to receive(:webhook_secret).and_call_original
    allow(StripeCredentials).to receive(:webhook_secret).with("test").and_return(signing_fixture)
    allow(StripeService).to receive(:create_door_checkout_session) do |payment:, line_items:, expires_at:|
      expect(line_items.sum { |item| item[:quantity] * item.dig(:price_data, :unit_amount) }).to eq(payment.amount_cents)
      session_fixture(payment, expires_at)
    end
  end

  def session_fixture(payment, expires_at, status: "open")
    id = "cs_test_Door#{payment.id}"
    OpenStruct.new(id: id, status: status, amount_total: payment.amount_cents, currency: "usd",
      livemode: false, expires_at: expires_at.to_i, url: "https://checkout.stripe.com/c/pay/#{id}")
  end

  def create_sale(**overrides)
    post path, params: cart.merge(overrides), headers: headers
    expect(response).to have_http_status(:ok), response.body
    Order.find(response.parsed_body.fetch("id"))
  end

  def payment_intent(order, **overrides)
    payment = order.payments.sole
    { id: "pi_Door#{payment.id}", amount_received: payment.amount_cents, currency: "usd", status: "succeeded",
      metadata: { hafapass_door_payment: payment.id.to_s, hafapass_door_checkout: order.checkout_key_digest } }.merge(overrides)
  end

  def send_event(type, object, id: "evt_Door#{SecureRandom.hex(6)}")
    payload = { id: id, type: type, livemode: false, created: Time.current.to_i, data: { object: object } }.to_json
    timestamp = Time.current
    signature = Stripe::Webhook::Signature.compute_signature(timestamp, payload, signing_fixture)
    post "/webhooks/stripe", params: payload,
      headers: { "Content-Type" => "application/json", "Stripe-Signature" => "t=#{timestamp.to_i},v1=#{signature}" }
    expect(response).to have_http_status(:ok), response.body
  end

  it "defaults to off and rejects a new sale before reserving inventory" do
    expect(create(:event).online_door_card_enabled?).to be(false)
    event.update!(online_door_card_enabled: false)
    expect(StripeService).not_to receive(:create_door_checkout_session)
    expect { post path, params: cart, headers: headers }.not_to change(Order, :count)
    expect(response).to have_http_status(:unprocessable_content)
  end

  it "allows only an admin to change the event switch" do
    event.update!(online_door_card_enabled: false)
    patch "/api/v1/admin/events/#{event.id}", params: { online_door_card_enabled: true }, headers: headers
    expect(response).to have_http_status(:forbidden)
    expect(event.reload.online_door_card_enabled?).to be(false)
    patch "/api/v1/admin/events/#{event.id}", params: { online_door_card_enabled: true }, headers: auth_headers(create(:user, :admin))
    expect(response).to have_http_status(:ok)
    expect(event.reload.online_door_card_enabled?).to be(true)
  end

  it "reserves the exact priced cart, shows the same session on retry, and hides tickets until paid" do
    expect(StripeService).not_to receive(:create_payment_intent)
    order = create_sale
    first = response.parsed_body
    expect(first).to include("status" => "waiting", "pending" => true, "tickets" => [])
    expect(order.service_fee_cents).to be_positive
    expect(order.expires_at).to be_within(2.seconds).of(35.minutes.from_now)
    expect(order.inventory_holds.sole).to have_attributes(expires_at: order.expires_at)
    expect(order.tickets).to be_empty
    expect(order.payments.sole).to have_attributes(provider: "stripe", provider_environment: "test")
    expect(order).to eq(create_sale)
    expect(response.parsed_body.fetch("checkout_url")).to eq(first.fetch("checkout_url"))
    expect(StripeService).to have_received(:create_door_checkout_session).once

    post path, params: cart.merge(payment_method: "door_card_keyed"), headers: headers
    expect(response).to have_http_status(:conflict)
    expect(Order.where(event: event).count).to eq(1)
  end

  it "retains the reservation and the exact Stripe request after a setup timeout" do
    attempts = []
    allow(StripeService).to receive(:create_door_checkout_session) do |payment:, line_items:, expires_at:|
      attempts << [payment.idempotency_key, line_items, expires_at]
      raise Timeout::Error if attempts.one?

      session_fixture(payment, expires_at)
    end
    post path, params: cart, headers: headers
    expect(response).to have_http_status(:bad_gateway)
    original_id = response.parsed_body.fetch("order_id")
    expect(Order.find(original_id).tickets).to be_empty
    expect(create_sale.id).to eq(original_id)
    expect(attempts).to eq([attempts.first, attempts.first])
  end

  it "scopes receipt, cancellation and email to the original seller with current event permission" do
    order = create_sale
    other_staff = create(:user)
    create(:organization_membership, organization: organization, user: other_staff, role: :box_office)
    create(:event_staff_assignment, event: event, user: other_staff, role: :box_office)
    other_headers = auth_headers(other_staff).merge("X-Organization-Id" => organization.id.to_s)
    get "#{path}/#{order.id}", headers: other_headers
    expect(response).to have_http_status(:not_found)
    delete "#{path}/#{order.id}", headers: other_headers
    expect(response).to have_http_status(:not_found)
    event.event_staff_assignments.where(user: staff).destroy_all
    get "#{path}/#{order.id}", headers: headers
    expect(response).to have_http_status(:forbidden)
    post "#{path}/#{order.id}/email", headers: headers
    expect(response).to have_http_status(:forbidden)
  end

  it "waits if Stripe completed while staff cancelled and fulfills only from the signed event" do
    order = create_sale(payment_method: "door_card_keyed")
    payment = order.payments.sole
    allow(StripeService).to receive(:expire_door_checkout_session).and_return(session_fixture(payment, order.expires_at, status: "complete"))
    delete "#{path}/#{order.id}", headers: headers
    expect(response.parsed_body).to include("status" => "waiting", "tickets" => [])
    expect { Commerce::PaymentRecovery.call(order: order) }.to raise_error(Commerce::PaymentRecovery::RecoveryError)

    expect do
      2.times { send_event("payment_intent.succeeded", payment_intent(order), id: "evt_DoorSuccess") }
      send_event("payment_intent.succeeded", payment_intent(order), id: "evt_DoorSuccessAgain")
    end.to change { order.tickets.count }.by(1)
    send_event("payment_intent.payment_failed", payment_intent(order, status: "requires_payment_method"))
    send_event("checkout.session.expired", { id: payment.reload.stripe_checkout_session_id, status: "expired" })

    expect(order.reload).to be_completed
    expect(payment.reload).to be_succeeded
    expect(payment.stripe_checkout_url).to be_nil
    expect(WebhookEvent.where(provider_event_id: "evt_DoorSuccess").count).to eq(1)
    get "#{path}/#{order.id}", headers: headers
    expect(response.parsed_body).to include("status" => "paid", "checkout_url" => nil, "pending" => false)
    expect(response.parsed_body.fetch("tickets").sole.fetch("scan_credential")).to eq(order.tickets.sole.scan_credential)
  end

  it "shows a retryable decline, releases on provider expiry, and queues one refund for a late capture" do
    order = create_sale
    payment = order.payments.sole
    send_event("payment_intent.payment_failed", payment_intent(order, status: "requires_payment_method"))
    get "#{path}/#{order.id}", headers: headers
    expect(response.parsed_body).to include("status" => "failed", "pending" => true, "tickets" => [])
    expect(order.inventory_holds.sole).to be_active

    send_event("checkout.session.expired", { id: payment.stripe_checkout_session_id, status: "expired" })
    expect(order.reload).to be_expired
    expect(order.inventory_holds.current).to be_empty
    expect(payment.reload.stripe_checkout_url).to be_nil
    expect do
      2.times { send_event("payment_intent.succeeded", payment_intent(order)) }
    end.to have_enqueued_job(LateCaptureRefundJob).with(payment.id).exactly(:once)
    expect(order.tickets).to be_empty
    expect(ReconciliationException.where(payment: payment, code: "late_payment_success_after_inventory_release").count).to eq(1)
  end

  it "releases a Session that expired before its create response was saved" do
    order = create_sale
    payment = order.payments.sole
    session_id = payment.stripe_checkout_session_id
    payment.update!(stripe_checkout_session_id: nil, stripe_checkout_url: nil)
    send_event("checkout.session.expired", { id: session_id, status: "expired",
      metadata: payment_intent(order).fetch(:metadata) })
    expect(order.reload).to be_expired
    expect(order.inventory_holds.current).to be_empty
    expect(payment.reload.stripe_checkout_session_id).to eq(session_id)
  end

  it "refunds rather than issues if the event was cancelled before confirmation" do
    order = create_sale
    event.update!(status: :cancelled)
    expect do
      send_event("payment_intent.succeeded", payment_intent(order))
    end.to have_enqueued_job(LateCaptureRefundJob).with(order.payments.sole.id)
    expect(order.tickets).to be_empty
    expect(order.reload).to be_expired
  end

  it "refunds a capture after the hold timestamp even before the expiry sweep" do
    order = create_sale
    travel_to(order.expires_at + 1.second) do
      expect(order.inventory_holds.current).to be_empty
      expect do
        send_event("payment_intent.succeeded", payment_intent(order))
      end.to have_enqueued_job(LateCaptureRefundJob).with(order.payments.sole.id)
    end
    expect(order.reload).to be_expired
    expect(order.tickets).to be_empty
  end

  it "records a mismatch without issuing tickets or overwriting the payment intent identity" do
    order = create_sale
    send_event("payment_intent.succeeded", payment_intent(order, amount_received: 1))
    expect(order.reload).to be_pending
    expect(order.tickets).to be_empty
    expect(order.payments.sole.provider_payment_id).to be_nil
    expect(ReconciliationException).to exist(order: order, code: "payment_context_mismatch")
  end

  it "cancels only after Stripe confirms expiry and clears the payment link" do
    order = create_sale
    payment = order.payments.sole
    allow(StripeService).to receive(:expire_door_checkout_session).and_raise(Stripe::APIConnectionError.new("fixture"))
    delete "#{path}/#{order.id}", headers: headers
    expect(response).to have_http_status(:bad_gateway)
    expect(order.reload).to be_pending
    expect(order.inventory_holds.current).to exist

    expect(StripeService).to receive(:expire_door_checkout_session).with(payment: payment, session_id: payment.stripe_checkout_session_id)
      .and_return(session_fixture(payment, order.expires_at, status: "expired"))
    delete "#{path}/#{order.id}", headers: headers
    expect(response.parsed_body).to include("status" => "cancelled", "pending" => false, "checkout_url" => nil)
    expect(order.inventory_holds.current).to be_empty
    expect(payment.reload.stripe_checkout_url).to be_nil
  end

  it "queues a requested phone link only once through simulated transactional delivery" do
    order = create_sale(buyer_email: "buyer@example.test")
    expect(Resend::Emails).not_to receive(:send)
    expect do
      2.times { post "#{path}/#{order.id}/email", headers: headers }
    end.to change { order.message_deliveries.where(template: "door_payment_link").count }.by(1)
    expect(response).to have_http_status(:accepted)
    delivery = order.message_deliveries.where(template: "door_payment_link").sole
    expect(delivery).to have_attributes(provider: "simulated", recipient: "buyer@example.test")
    MessageDeliveryJob.perform_now(delivery.id)
    expect(delivery.reload).to be_sent
  end

  it "reports the two hosted methods separately and includes their proceeds in the Stripe-paid settlement" do
    phone = create_sale
    send_event("payment_intent.succeeded", payment_intent(phone))
    post path, params: cart.merge(payment_method: "door_card_keyed"),
      headers: headers.merge("Idempotency-Key" => "box-office-#{SecureRandom.uuid}")
    expect(response).to have_http_status(:ok)
    keyed = Order.find(response.parsed_body.fetch("id"))
    send_event("payment_intent.succeeded", payment_intent(keyed))
    [
      ["door_cash", 2500],
      ["door_card", 1300]
    ].each do |method, cents|
      create(:order, :completed, event: event, total_cents: cents, subtotal_cents: cents,
        service_fee_cents: 0, source: "box_office", payment_method: method)
    end

    get "/api/v1/organizer/events/#{event.id}/box_office/summary", headers: headers
    expect(response.parsed_body.fetch("by_payment_method")).to eq(
      "door_cash" => 2500, "door_card" => 1300, "door_card_link" => phone.total_cents, "door_card_keyed" => keyed.total_cents
    )
    channels = EventSalesAnalytics.call(event).fetch(:sales_by_channel).index_by { |row| row[:channel] }
    expect(channels.fetch("door_card_link")[:orders]).to eq(1)
    expect(channels.fetch("door_card_keyed")[:orders]).to eq(1)
    expect(FinanceExports.each_order_row([event]).map { |row| row[:payment_method] }).to contain_exactly(
      "door_cash", "door_card", "door_card_link", "door_card_keyed"
    )
    lines = Settlements::Calculator.new(event).call.items
    hosted_lines = lines.select { |line| line[:metadata][:payment_method].in?(Order::ONLINE_DOOR_CARD_METHODS) }
    expect(hosted_lines.pluck(:kind)).to eq(["sale_proceeds", "sale_proceeds"])
    expect(hosted_lines.sum { |line| line[:amount_cents] }).to eq(2400)
    expect(phone.payments.sole.provider).to eq("stripe")
  end
end
