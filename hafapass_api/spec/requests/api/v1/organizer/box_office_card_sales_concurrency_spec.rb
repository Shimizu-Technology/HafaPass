# frozen_string_literal: true

require "rails_helper"
require "ostruct"
require "timeout"

RSpec.describe "Online box office shared capacity", :non_transactional, type: :request do
  self.use_transactional_tests = false

  before do
    clean_test_data
    SiteSetting.instance.update_columns(payment_mode: "test")
    allow(StripeService).to receive(:payment_enabled?).and_return(true)
    allow(StripeService).to receive(:platform_account_id).with("test").and_return("acct_DoorConcurrencyFixture")
  end

  after { clean_test_data }

  it "holds the last admission for the original pending sale while an online buyer tries to take it" do
    event = create(:event, :published, online_door_card_enabled: true, max_capacity: 1, starts_at: 3.days.from_now)
    ticket_type = create(:ticket_type, event: event, price_cents: 1200, quantity_available: 1)
    owner = event.organizer_profile.user
    method = "door_card_link"
    line_items = [{ ticket_type_id: ticket_type.id, quantity: 1 }]
    path = "/api/v1/organizer/events/#{event.id}/box_office_card_sales"
    headers = auth_headers(owner).merge("Idempotency-Key" => "box-office-#{SecureRandom.uuid}")
    gateway_entered = Queue.new
    gateway_release = Queue.new
    responses = Queue.new
    calls = Queue.new
    allow(StripeService).to receive(:create_door_checkout_session) do |payment:, line_items:, expires_at:|
      expect(ActiveRecord::Base.connection.transaction_open?).to be(false)
      calls << [payment.idempotency_key, line_items, expires_at]
      gateway_entered << true
      gateway_release.pop
      id = "cs_test_Concurrent#{payment.id}"
      OpenStruct.new(id: id, status: "open", amount_total: payment.amount_cents, currency: "usd",
        livemode: false, expires_at: expires_at.to_i, url: "https://checkout.stripe.com/c/pay/#{id}")
    end
    first_request = Thread.new do
      ActiveRecord::Base.connection_pool.with_connection do
        session = ActionDispatch::Integration::Session.new(Rails.application)
        session.post(path, params: { payment_method: method, line_items: line_items }, headers: headers)
        responses << session.response
      rescue StandardError => error
        responses << error
      end
    end
    Timeout.timeout(30) { gateway_entered.pop }

    pending = event.orders.sole
    expect(pending.inventory_holds.current.sum(:quantity)).to eq(1)
    expect(pending.tickets).to be_empty
    expect do
      Commerce::OrderCreator.call(event: Event.find(event.id), line_items: line_items, buyer_email: "buyer@example.test",
        buyer_name: "Buyer", enforce_buyer_limits: true, payment_required: true)
    end.to raise_error(Commerce::OrderCreator::CheckoutError, /Only 0/)

    post path, params: { payment_method: method, line_items: line_items }, headers: headers
    expect(response).to have_http_status(:ok)
    second = response.parsed_body
    expect(second).to include("id" => pending.id, "status" => "waiting", "checkout_url" => nil)
    gateway_release << true
    Timeout.timeout(15) { first_request.join }
    first = responses.pop
    expect(first).not_to be_a(Exception)
    expect(first.parsed_body).to include("id" => pending.id, "status" => "waiting")
    expect(first.parsed_body.fetch("checkout_url")).to start_with("https://checkout.stripe.com/")
    post path, params: { payment_method: method, line_items: line_items }, headers: headers
    expect(response.parsed_body).to eq(first.parsed_body)
    expect(calls.size).to eq(1)
    expect(event.orders.count).to eq(1)
    expect(Payment.where(order: pending).count).to eq(1)
    expect(ticket_type.reload.quantity_sold).to eq(0)

    ExpireInventoryHoldsJob.perform_now(pending.expires_at + 1.second)
    expect(pending.reload).to be_expired
    expect(pending.inventory_holds.current).to be_empty
    expect(ticket_type.reload.available_quantity).to eq(1)
  ensure
    gateway_release << true if gateway_release
    first_request&.join(2)
    first_request&.kill if first_request&.alive?
  end

  def clean_test_data
    raise "Isolated test database required" unless Rails.env.test? && ActiveRecord::Base.connection_db_config.database.end_with?("_test")

    ActiveRecord::Base.connection.execute("TRUNCATE TABLE audit_logs, audit_write_failures, users, organizer_profiles, events, site_settings, checkout_attempts RESTART IDENTITY CASCADE")
  end
end
