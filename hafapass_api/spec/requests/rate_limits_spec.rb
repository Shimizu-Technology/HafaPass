require "rails_helper"

RSpec.describe "Request throttles", type: :request do
  include ActiveSupport::Testing::TimeHelpers

  # Keep each burst in one fixed throttle window, even across a wall-clock minute.
  around do |example|
    freeze_time { example.run }
  end

  let(:event) { create(:event, :published, starts_at: 5.days.from_now) }
  let(:ticket_type) { create(:ticket_type, :free, event: event) }

  before do
    allow(EmailService).to receive(:send_order_confirmation_async)
  end

  def checkout(email)
    post "/api/v1/orders", params: {
      event_id: event.id, buyer_email: email, buyer_name: "Throttle Buyer",
      terms_accepted: true, terms_version: PolicyRegistry.buyer_terms[:version],
      line_items: [{ ticket_type_id: ticket_type.id, quantity: 1 }]
    }, as: :json
  end

  it "enforces the five-order buyer limit within one example, without creating the rejected order" do
    5.times do
      checkout("throttle@example.invalid")
      expect(response).to have_http_status(:created)
    end
    expect { checkout("throttle@example.invalid") }.not_to change(Order, :count)
    expect(response).to have_http_status(:too_many_requests)
  end

  it "starts with fresh counters and enforces the ten-order IP limit across different buyers" do
    10.times do |index|
      checkout("buyer#{index}@example.invalid")
      expect(response).to have_http_status(:created)
    end
    expect { checkout("next-buyer@example.invalid") }.not_to change(Order, :count)
    expect(response).to have_http_status(:too_many_requests)
  end
end
