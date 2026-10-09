require "rails_helper"

RSpec.describe "Buyer payment recovery", type: :request do
  let(:event) { create(:event, :published, starts_at: 5.days.from_now) }
  let(:ticket_type) { create(:ticket_type, event: event, price_cents: 1000, quantity_available: 10) }
  let(:key) { SecureRandom.hex(32) }
  let(:params) do
    { event_id: event.id, buyer_email: "recover@example.invalid", buyer_name: "Recover Buyer",
      terms_accepted: true, terms_version: PolicyRegistry.buyer_terms[:version], checkout_key: key,
      line_items: [{ ticket_type_id: ticket_type.id, quantity: 1 }] }
  end
  let(:intents) { double("payment intent API") }
  let(:intent) do
    OpenStruct.new(id: "pi_recover", client_secret: "pi_recover_secret", amount: @order.total_cents,
      currency: "usd", livemode: false, status: "requires_payment_method", amount_received: 0)
  end

  before do
    allow(EmailService).to receive(:send_order_confirmation_async)
    SiteSetting.instance.update!(payment_mode: "test")
    allow(ENV).to receive(:[]).and_call_original
    allow(ENV).to receive(:[]).with("STRIPE_TEST_SECRET_KEY").and_return("sk_test_recovery")
    allow(ENV).to receive(:[]).with("STRIPE_TEST_PLATFORM_ACCOUNT_ID").and_return("acct_testplatform")
    allow(ENV).to receive(:[]).with("STRIPE_TEST_PUBLISHABLE_KEY").and_return("pk_test_recovery")
    allow(StripeService).to receive(:create_payment_intent).and_return(OpenStruct.new(id: "pi_recover", client_secret: "pi_recover_secret"))
    client = instance_double(Stripe::StripeClient, v1: double("v1", payment_intents: intents, accounts: double("accounts", retrieve_current: OpenStruct.new(id: "acct_testplatform"))))
    allow(Stripe::StripeClient).to receive(:new).with("sk_test_recovery").and_return(client)
    allow(intents).to receive(:retrieve) { intent }
    allow(intents).to receive(:cancel).and_return(OpenStruct.new(status: "canceled"))
    post "/api/v1/orders", params: params, as: :json
    expect(response).to have_http_status(:created)
    @order = Order.find(response.parsed_body.fetch("id"))
    @guest_token = response.parsed_body.fetch("guest_access_token")
  end

  def resume(headers = { "X-Guest-Order-Token" => @guest_token })
    post "/api/v1/orders/#{@order.id}/payment_resume", headers: headers, as: :json
  end

  it "resumes the original unpaid intent and amount, without issuing tickets or another intent" do
    resume
    expect(response).to have_http_status(:ok)
    expect(response.parsed_body).to include("id" => @order.id, "client_secret" => "pi_recover_secret", "payment_state" => "requires_payment_method")
    expect(@order.reload).to be_pending
    expect(@order.tickets).to be_empty
    expect(StripeService).to have_received(:create_payment_intent).once
  end

  it "returns no secret to anonymous strangers or administrators managing another buyer" do
    resume({})
    expect(response).to have_http_status(:not_found)
    admin = create(:user, :admin)
    allow(ClerkAuthenticator).to receive(:verify).with("admin-token").and_return({ "sub" => admin.clerk_id })
    resume({ "Authorization" => "Bearer admin-token" })
    expect(response).to have_http_status(:not_found)
    expect(intents).not_to have_received(:retrieve)
  end

  it "does not expose a provider secret after the hold expires" do
    @order.update!(expires_at: 1.minute.ago)
    resume
    expect(response).to have_http_status(:ok)
    expect(response.parsed_body).not_to have_key("client_secret")
    expect(@order.reload).to be_expired
    expect(intents).not_to have_received(:retrieve)
  end

  it "rejects an incorrect amount rather than returning a secret" do
    intent.amount += 1
    resume
    expect(response).to have_http_status(:unprocessable_entity)
    expect(response.parsed_body).not_to have_key("client_secret")
    expect(@order.reload).to be_pending
  end

  { currency: "eur", livemode: true }.each do |field, incorrect_value|
    it "rejects mismatched #{field} before exposing a secret" do
      intent.public_send("#{field}=", incorrect_value)
      resume
      expect(response).to have_http_status(:unprocessable_entity)
      expect(response.parsed_body).not_to have_key("client_secret")
    end
  end

  it "does not expose another confirmation secret after event sales are suspended" do
    event.update!(sales_suspended_at: Time.current)
    resume
    expect(response).to have_http_status(:unprocessable_entity)
    expect(response.parsed_body).not_to have_key("client_secret")
  end

  it "keeps a provider-processing payment on confirmation without allowing another confirmation" do
    intent.status = "processing"
    resume
    expect(response.parsed_body).to include("payment_state" => "processing", "payment_resumable" => false)
    expect(response.parsed_body).not_to have_key("client_secret")
  end

  it "recovers a lost creation response with one order and one set of holds using only a hashed key" do
    expect { post "/api/v1/orders", params: params, as: :json }.not_to change(Order, :count)
    expect(response).to have_http_status(:created)
    expect(response.parsed_body["id"]).to eq(@order.id)
    expect(response.parsed_body["guest_access_token"]).to be_present
    expect(@order.reload.checkout_key_digest).to eq(Digest::SHA256.hexdigest(key))
    expect(@order.inventory_holds.count).to eq(1)
    expect(StripeService).to have_received(:create_payment_intent).once
  end

  it "rejects replay with changed buyer details and expired recovery capability" do
    post "/api/v1/orders", params: params.merge(buyer_email: "other@example.invalid"), as: :json
    expect(response).to have_http_status(:unprocessable_entity)
    expect(response.parsed_body).not_to have_key("guest_access_token")
    Order.where(id: @order.id).update_all(checkout_recovery_expires_at: 1.minute.ago)
    post "/api/v1/orders", params: params, as: :json
    expect(response).to have_http_status(:unprocessable_entity)
    expect(Order.count).to eq(1)
  end
end
