require "rails_helper"

RSpec.describe "Buyer payment recovery", type: :request do
  include ActiveSupport::Testing::TimeHelpers

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
      currency: "usd", livemode: false, status: "requires_payment_method", amount_received: 0,
      allowed_payment_method_types: ["card"], payment_method_types: ["card"])
  end

  before do
    allow(EmailService).to receive(:send_order_confirmation_async)
    SiteSetting.instance.update!(payment_mode: "test")
    allow(ENV).to receive(:[]).and_call_original
    allow(ENV).to receive(:[]).with("STRIPE_TEST_SECRET_KEY").and_return("sk_test_recovery")
    allow(ENV).to receive(:[]).with("STRIPE_TEST_PLATFORM_ACCOUNT_ID").and_return("acct_testplatform")
    allow(ENV).to receive(:[]).with("STRIPE_TEST_PUBLISHABLE_KEY").and_return("pk_test_recovery")
    allow(StripeService).to receive(:create_payment_intent).and_return(OpenStruct.new(id: "pi_recover", client_secret: "pi_recover_secret",
      allowed_payment_method_types: ["card"], payment_method_types: ["card"]))
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

  [nil, [], ["card", "us_bank_account"], ["unknown_method"]].each do |allowed|
    it "blocks the unsupported #{allowed.inspect} policy without duplicating or cancelling the original operation" do
      intent.allowed_payment_method_types = allowed
      intent.payment_method_types = allowed || ["card"]
      intent.automatic_payment_methods = OpenStruct.new(enabled: true) if allowed.nil?
      expect { resume }.not_to change { [Order.count, Payment.count, InventoryHold.count] }
      expect(response).to have_http_status(:unprocessable_entity)
      expect(response.parsed_body).not_to have_key("client_secret")
      expect(@order.reload).to be_pending
      expect(@order.payments.last.provider_payment_id).to eq("pi_recover")
      expect(@order.reconciliation_exceptions.open).to exist(code: "payment_method_policy_mismatch")
      expect(intents).not_to have_received(:cancel)
      expect(StripeService).to have_received(:create_payment_intent).once
    end
  end

  it "blocks an unexpectedly broad compatible response even when its declared allowlist is card-only" do
    intent.payment_method_types = ["card", "us_bank_account"]
    resume
    expect(response).to have_http_status(:unprocessable_entity)
    expect(response.parsed_body).not_to have_key("client_secret")
  end

  it "leaves an already processing legacy bank operation intact and exposes no confirmation secret" do
    intent.status = "processing"
    intent.allowed_payment_method_types = nil
    intent.payment_method_types = ["us_bank_account"]
    expect { resume }.not_to change { [Order.count, Payment.count, InventoryHold.count] }
    expect(response).to have_http_status(:ok)
    expect(response.parsed_body).to include("payment_state" => "processing", "payment_resumable" => false)
    expect(response.parsed_body).not_to have_key("client_secret")
    expect(@order.reload).to be_pending
    expect(intents).not_to have_received(:cancel)
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

  it "does not hold a row lock during provider retrieval and rejects a concurrently cancelled reservation" do
    transactions_before = ActiveRecord::Base.connection.open_transactions
    allow(intents).to receive(:retrieve) do
      expect(ActiveRecord::Base.connection.open_transactions).to eq(transactions_before)
      Commerce::OrderLifecycle.cancel!(Order.find(@order.id))
      intent
    end
    allow(intents).to receive(:cancel) do
      expect(ActiveRecord::Base.connection.open_transactions).to eq(transactions_before)
      OpenStruct.new(status: "canceled")
    end
    resume
    expect(response).to have_http_status(:ok)
    expect(response.parsed_body).to include("status" => "cancelled")
    expect(response.parsed_body).not_to have_key("client_secret")
  end

  it "cancels expiry outside the recovery transaction and records an unknown cancellation" do
    @order.update!(expires_at: 1.minute.ago)
    transactions_before = ActiveRecord::Base.connection.open_transactions
    allow(intents).to receive(:cancel) do
      expect(ActiveRecord::Base.connection.open_transactions).to eq(transactions_before)
      raise Timeout::Error, "Cancellation acknowledgement unavailable"
    end
    resume
    expect(response).to have_http_status(:ok)
    expect(response.parsed_body).not_to have_key("client_secret")
    expect(@order.reload).to be_expired
    expect(@order.reconciliation_exceptions).to exist(code: "provider_payment_cancel_failed")
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
    expect(CheckoutAttempt.find_by!(checkout_key_digest: Digest::SHA256.hexdigest(key)).order_id).to eq(@order.id)
  end

  it "recovers the original reservation after buyer terms change without requiring another checkout" do
    original_params = params.deep_dup
    allow(PolicyRegistry).to receive(:buyer_terms).and_return(PolicyRegistry.buyer_terms.merge(version: "next-version"))
    post "/api/v1/orders", params: original_params, as: :json
    expect(response).to have_http_status(:created)
    expect(response.parsed_body["id"]).to eq(@order.id)
    expect(Order.count).to eq(1)
    expect(StripeService).to have_received(:create_payment_intent).once
  end

  it "keeps a reserved original recoverable when an event gate prevents returning its secret" do
    event.update!(sales_suspended_at: Time.current)
    post "/api/v1/orders", params: params, as: :json
    expect(response).to have_http_status(:unprocessable_entity)
    expect(response.parsed_body["checkout_recovery_required"]).to be(true)
    expect(response.parsed_body).not_to have_key("client_secret")
    expect(CheckoutAttempt.last).to be_status_reserved
    expect(Order.count).to eq(1)
  end

  it "binds recovery to the original authenticated identity as well as the request body" do
    user = create(:user)
    post "/api/v1/orders", params: params, headers: auth_headers(user), as: :json
    expect(response).to have_http_status(:unprocessable_entity)
    expect(response.parsed_body["checkout_recovery_required"]).to be(true)
    expect(response.parsed_body).not_to have_key("guest_access_token")
    expect(Order.count).to eq(1)
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

  it "returns no confirmation secret when the original checkout was cancelled before replay" do
    Commerce::OrderLifecycle.cancel!(@order)
    expect { post "/api/v1/orders", params: params, as: :json }.not_to change(Order, :count)
    expect(response).to have_http_status(:created)
    expect(response.parsed_body).to include("id" => @order.id, "status" => "cancelled")
    expect(response.parsed_body).not_to have_key("client_secret")
    expect(StripeService).to have_received(:create_payment_intent).once
    expect(intents).not_to have_received(:retrieve)
  end

  [Stripe::APIConnectionError, Stripe::IdempotencyError].each do |error_class|
    it "recovers the same payment setup after #{error_class.name} without releasing its reservation" do
      retry_params = params.merge(checkout_key: SecureRandom.hex(32), buyer_email: "setup-retry@example.invalid")
      allow(StripeService).to receive(:create_payment_intent).and_raise(error_class.new("response unavailable"))
      post "/api/v1/orders", params: retry_params, as: :json
      expect(response).to have_http_status(:unprocessable_entity)
      expect(response.parsed_body).to include("checkout_recovery_required" => true)
      expect(response.parsed_body).not_to have_key("client_secret")
      retained = Order.find_by!(buyer_email: "setup-retry@example.invalid")
      payment = retained.payments.last
      expect(retained).to be_pending
      expect(payment).to have_attributes(status: "pending", provider_payment_id: nil,
        failure_code: "payment_setup_result_unknown")
      expect(retained.inventory_holds.current.sum(:quantity)).to eq(1)
      original_identity = payment.attributes.slice("id", "idempotency_key", "provider_environment", "provider_platform_account_id")
      expect(intents).not_to have_received(:cancel)

      allow(StripeService).to receive(:create_payment_intent).and_return(OpenStruct.new(id: "pi_setup_recovered",
        client_secret: "same_setup_secret", allowed_payment_method_types: ["card"], payment_method_types: ["card"]))
      expect { post "/api/v1/orders", params: retry_params, as: :json }.not_to change { [Order.count, Payment.count, InventoryHold.count] }
      expect(response).to have_http_status(:created)
      expect(response.parsed_body).to include("id" => retained.id, "client_secret" => "same_setup_secret")
      expect(payment.reload.attributes.slice(*original_identity.keys)).to eq(original_identity)
      expect(payment).to have_attributes(provider_payment_id: "pi_setup_recovered", failure_code: nil)
      expect(StripeService).to have_received(:create_payment_intent).with(retained,
        idempotency_key: original_identity.fetch("idempotency_key"), payment: payment).twice
    end
  end

  it "releases a definitively rejected setup and never returns a secret when its request is replayed" do
    rejected_params = params.merge(checkout_key: SecureRandom.hex(32), buyer_email: "setup-rejected@example.invalid")
    allow(StripeService).to receive(:create_payment_intent)
      .and_raise(Stripe::InvalidRequestError.new("Rejected request", "amount"))
    post "/api/v1/orders", params: rejected_params, as: :json
    expect(response).to have_http_status(:unprocessable_entity)
    rejected = Order.find_by!(buyer_email: "setup-rejected@example.invalid")
    expect(rejected).to be_cancelled
    expect(rejected.payments.last).to be_failed
    expect(rejected.inventory_holds).to all(be_released)

    expect { post "/api/v1/orders", params: rejected_params, as: :json }.not_to change { [Order.count, Payment.count] }
    expect(response.parsed_body).to include("id" => rejected.id, "status" => "cancelled")
    expect(response.parsed_body).not_to have_key("client_secret")
    expect(StripeService).to have_received(:create_payment_intent).with(rejected,
      idempotency_key: rejected.payments.last.idempotency_key, payment: rejected.payments.last).once
  end

  it "does not erase an earlier unknown creation when a later replay is rejected" do
    unknown_params = params.merge(checkout_key: SecureRandom.hex(32), buyer_email: "setup-unknown@example.invalid")
    allow(StripeService).to receive(:create_payment_intent).and_raise(Stripe::APIConnectionError.new("acknowledgement lost"))
    post "/api/v1/orders", params: unknown_params, as: :json
    original = Order.find_by!(buyer_email: "setup-unknown@example.invalid")
    payment = original.payments.last
    identity = payment.idempotency_key
    allow(StripeService).to receive(:create_payment_intent).and_raise(Stripe::InvalidRequestError.new("Rejected replay", "amount"))
    post "/api/v1/orders", params: unknown_params, as: :json
    expect(response).to have_http_status(:unprocessable_entity)
    expect(response.parsed_body["error"]).to include("result is unknown")
    expect(response.parsed_body).not_to have_key("client_secret")
    expect(original.reload).to be_pending
    expect(payment.reload).to have_attributes(status: "pending", failure_code: "payment_setup_result_unknown", idempotency_key: identity)
    expect(original.inventory_holds.current.sum(:quantity)).to eq(1)
  end

  it "recovers an interrupted setup after its committed lease expires using the original identity" do
    interrupted_params = params.merge(checkout_key: SecureRandom.hex(32), buyer_email: "setup-interrupted@example.invalid")
    crash = Class.new(Exception)
    allow(StripeService).to receive(:create_payment_intent).and_raise(crash, "request process stopped")
    expect { post "/api/v1/orders", params: interrupted_params, as: :json }.to raise_error(crash)
    interrupted = Order.find_by!(buyer_email: "setup-interrupted@example.invalid")
    payment = interrupted.payments.last
    original = payment.attributes.slice("idempotency_key", "provider_environment", "provider_platform_account_id")
    first_attempt = payment.provider_payload.fetch("setup_attempted_at")
    expect(payment.provider_payload["setup_lease_token"]).to be_present
    post "/api/v1/orders", params: interrupted_params, as: :json
    expect(response).to have_http_status(:unprocessable_entity)
    expect(response.parsed_body["error"]).to include("still in progress")

    allow(StripeService).to receive(:create_payment_intent).and_return(OpenStruct.new(id: "pi_interrupted_setup",
      client_secret: "recovered_secret", allowed_payment_method_types: ["card"], payment_method_types: ["card"]))
    travel 65.seconds do
      post "/api/v1/orders", params: interrupted_params, as: :json
    end
    expect(response).to have_http_status(:created)
    expect(response.parsed_body).to include("id" => interrupted.id, "client_secret" => "recovered_secret")
    expect(payment.reload.attributes.slice(*original.keys)).to eq(original)
    expect(payment.provider_payload).to include("setup_attempted_at" => first_attempt)
    expect(payment.provider_payload).not_to have_key("setup_lease_token")
    expect(interrupted.inventory_holds.current.sum(:quantity)).to eq(1)
    expect(StripeService).to have_received(:create_payment_intent).with(interrupted,
      idempotency_key: original.fetch("idempotency_key"), payment: payment).twice
  end
end
