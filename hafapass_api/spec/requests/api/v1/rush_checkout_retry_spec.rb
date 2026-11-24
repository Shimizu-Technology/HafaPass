# frozen_string_literal: true

require "rails_helper"

# A sell-out through the real checkout endpoint: the pre-lock refusal must not
# break same-key recovery, and a refused key stays refused (CheckoutAttempt).
RSpec.describe "Checkout retries during a sell-out", type: :request do
  let(:event) { create(:event, :published, starts_at: 5.days.from_now) }
  let!(:ticket_type) { create(:ticket_type, :free, event: event, name: "Final GA", quantity_available: 1, max_per_order: 1) }

  def checkout(key, email, platform_opt_in: false)
    params = { event_id: event.id, buyer_email: email, buyer_name: "Rush Buyer", terms_accepted: true,
      terms_version: PolicyRegistry.buyer_terms[:version], checkout_key: key, platform_opt_in: platform_opt_in,
      line_items: [{ ticket_type_id: ticket_type.id, quantity: 1 }] }
    post "/api/v1/orders", params: params.to_json, headers: { "Content-Type" => "application/json" }
  end

  def attempt_for(key)
    CheckoutAttempt.find_by!(checkout_key_digest: Digest::SHA256.hexdigest(key))
  end

  it "keeps a final-ticket order and its recovery when optional consent enqueue fails" do
    allow(CheckoutSubscriptionJob).to receive(:perform_later).and_raise(ActiveRecord::RecordInvalid)
    expect(PublicEventCache).to receive(:bump_after_commit!).at_least(:once).and_call_original
    key = SecureRandom.hex(32)

    checkout(key, "winner@example.invalid", platform_opt_in: true)
    expect(response).to have_http_status(:created)
    order = Order.find(response.parsed_body.fetch("id"))
    expect(order).to be_completed
    expect(order.tickets.count).to eq(1)
    expect(ticket_type.reload.quantity_sold).to eq(1)
    expect(CheckoutSubscriptionJob).to have_received(:perform_later).once

    expect { checkout(key, "winner@example.invalid", platform_opt_in: true) }.not_to change(Order, :count)
    expect(response).to have_http_status(:created)
    expect(response.parsed_body.fetch("id")).to eq(order.id)

    expect { checkout(SecureRandom.hex(32), "late@example.invalid", platform_opt_in: true) }.not_to change(Order, :count)
    expect(response).to have_http_status(:unprocessable_content)
    expect(response.parsed_body.fetch("error")).to eq("Only 0 tickets available for Final GA")
    expect(CheckoutSubscriptionJob).to have_received(:perform_later).twice
  end

  it "returns the winner's order to its same-key retry and refuses a late buyer for good" do
    winner_key = SecureRandom.hex(32)
    checkout(winner_key, "winner@example.invalid")
    expect(response).to have_http_status(:created)
    order_id = response.parsed_body.fetch("id")
    expect(Order.find(order_id)).to be_completed
    expect(ticket_type.reload.available_quantity).to eq(0)

    late_key = SecureRandom.hex(32)
    statements = []
    callback = ->(*, payload) { statements << payload[:sql] }
    ActiveSupport::Notifications.subscribed(callback, "sql.active_record") { checkout(late_key, "late@example.invalid") }
    expect(response).to have_http_status(:unprocessable_content)
    expect(response.parsed_body).to include("error" => "Only 0 tickets available for Final GA", "checkout_recovery_required" => false)
    # Refused before the event lock.
    expect(statements.grep(/FROM "events".*FOR NO KEY UPDATE/)).to be_empty
    expect(attempt_for(late_key)).to be_status_rejected

    expect { checkout(winner_key, "winner@example.invalid") }.not_to change(Order, :count)
    expect(response).to have_http_status(:created)
    expect(response.parsed_body.fetch("id")).to eq(order_id)
    expect(attempt_for(winner_key).order_id).to eq(order_id)

    # Inventory coming back does not revive a refused key.
    ticket_type.update!(quantity_available: 2)
    expect { checkout(late_key, "late@example.invalid") }.not_to change(Order, :count)
    expect(response).to have_http_status(:unprocessable_content)
    expect(response.parsed_body).to include("checkout_recovery_required" => false)
    expect(ticket_type.reload.quantity_sold).to eq(1)
  end
end
