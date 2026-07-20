require "rails_helper"

RSpec.describe "Api::V1::Support", type: :request do
  let(:support_user) { create(:user, role: :support) }
  let(:attendee) { create(:user, role: :attendee) }
  let(:order) { create(:order, reference: "HP-SUPPORT-123", buyer_email: "islandbuyer@example.com") }

  it "allows support to find operational records without financial configuration" do
    create(:ticket, order: order, event: order.event, ticket_type: create(:ticket_type, event: order.event))

    get "/api/v1/support/search", params: { q: "SUPPORT" }, headers: auth_headers(support_user)

    expect(response).to have_http_status(:ok)
    expect(response.parsed_body["orders"].first).to include("reference" => "HP-SUPPORT-123")
    expect(response.parsed_body.to_json).not_to include("provider_payment_id", "payout", "connected_account")
    expect(AuditLog.where(actor_user: support_user, action: "support.lookup")).to exist
  end

  it "denies the support console to an attendee" do
    get "/api/v1/support/search", params: { q: "SUPPORT" }, headers: auth_headers(attendee)

    expect(response).to have_http_status(:forbidden)
  end

  it "replays only failed delivery records and audits the actor" do
    delivery = create(:message_delivery, order: order, event: order.event, status: :failed)

    expect do
      post "/api/v1/support/message_deliveries/#{delivery.id}/resend", headers: auth_headers(support_user)
    end.to have_enqueued_job(MessageDeliveryJob).with(delivery.id)

    expect(response).to have_http_status(:accepted)
    expect(AuditLog.where(actor_user: support_user, action: "message_delivery.replayed", auditable: delivery)).to exist
  end

  it "creates append-only support notes" do
    post "/api/v1/support/notes", params: { order_id: order.id, body: "Buyer confirmed the corrected address." },
      headers: auth_headers(support_user)

    expect(response).to have_http_status(:created)
    note = SupportNote.last
    expect(note.author_user).to eq(support_user)
    expect(note.update(body: "rewritten")).to be(false)
  end
end
