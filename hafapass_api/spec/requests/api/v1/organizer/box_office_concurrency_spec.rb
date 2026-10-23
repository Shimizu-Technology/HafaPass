require "rails_helper"
require "timeout"

RSpec.describe "Overlapping terminal requests", :non_transactional, type: :request do
  self.use_transactional_tests = false

  before do
    clean_test_data
    allow(EmailService).to receive(:send_order_confirmation_async)
  end

  after { clean_test_data }

  it "returns reconciliation-required without another charge while preserving the original eventual success" do
    event = create(:event, :published)
    user = event.organizer_profile.user
    create(:card_present_account, :verified, organization: event.organization)
    ticket_type = create(:ticket_type, event: event, price_cents: 1000)
    payload = { line_items: [{ ticket_type_id: ticket_type.id, quantity: 1 }], payment_method: "door_card",
      buyer_name: "Overlap fixture", buyer_email: "overlap@example.invalid" }
    headers = auth_headers(user).merge("Idempotency-Key" => "original-in-flight-key")
    path = "/api/v1/organizer/events/#{event.id}/box_office"
    provider_entered = Queue.new
    provider_release = Queue.new
    original_responses = Queue.new
    gateway = instance_double(CardPresentGateway)
    allow(CardPresentGateway).to receive(:new).and_return(gateway)
    expect(gateway).to receive(:charge).once do |**arguments|
      expect(ActiveRecord::Base.connection.transaction_open?).to be(false)
      provider_entered << true
      provider_release.pop
      CardPresentGateway::Result.new(provider_payment_id: "clover-original-overlap", amount_cents: arguments[:amount_cents],
        currency: "usd", state: "CLOSED", result: "SUCCESS", provider_response: { "id" => "clover-original-overlap" })
    end
    original = Thread.new do
      ActiveRecord::Base.connection_pool.with_connection do
        session = ActionDispatch::Integration::Session.new(Rails.application)
        session.post(path, params: payload, headers: headers)
        original_responses << session.response
      rescue StandardError => error
        original_responses << error
      end
    end
    # The request must reach the provider, but database setup can take longer
    # than five seconds on a loaded test host.
    Timeout.timeout(30) { provider_entered.pop }
    attempt = CardPresentPaymentAttempt.find_by!(idempotency_key: "original-in-flight-key")
    original_expiry = attempt.order.expires_at
    expect(attempt).to be_status_initiated

    expect { post path, params: payload, headers: headers }.not_to change(Order, :count)
    expect(response).to have_http_status(:bad_gateway)
    expect(response.parsed_body).to include("reconciliation_required" => true, "payment_status" => "result_unknown",
      "order_id" => attempt.order_id)
    expect(attempt.reload).to be_status_result_unknown
    expect(attempt.order.reload.expires_at).to be > original_expiry
    expect(attempt.order.inventory_holds).to all(be_active)
    expect(attempt.order.tickets).to be_empty
    expect(ReconciliationException.open).to exist(order: attempt.order, code: "card_present_result_unknown")

    provider_release << true
    Timeout.timeout(10) { original.join }
    original_response = original_responses.pop
    expect(original_response).not_to be_a(Exception)
    expect(original_response.status).to eq(201)
    expect(attempt.reload).to be_status_succeeded
    expect(attempt.order.reload).to be_completed
    expect(attempt.payment.reload).to be_succeeded
    expect(attempt.order.tickets.count).to eq(1)
    expect(ticket_type.reload.quantity_sold).to eq(1)
    expect(ReconciliationException.open.where(order: attempt.order, code: "card_present_result_unknown")).not_to exist

    expect { post path, params: payload, headers: headers }.not_to change(Order, :count)
    expect(response).to have_http_status(:ok)
    expect(response.parsed_body.fetch("id")).to eq(attempt.order_id)
    expect(CardPresentPaymentAttempt.count).to eq(1)
  ensure
    provider_release << true if provider_release
    original&.join(2)
    original&.kill if original&.alive?
  end

  def clean_test_data
    raise "Isolated test database required" unless Rails.env.test? && ActiveRecord::Base.connection_db_config.database.end_with?("_test")

    ActiveRecord::Base.connection.execute("TRUNCATE TABLE audit_logs, audit_write_failures, users, organizer_profiles, events, site_settings RESTART IDENTITY CASCADE")
  end
end
