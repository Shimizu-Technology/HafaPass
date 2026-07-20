require "rails_helper"

RSpec.describe "Organizer guest list redemption", type: :request do
  let(:user) { create(:user, :organizer) }
  let(:profile) { create(:organizer_profile, user: user) }
  let(:event) { create(:event, :published, organizer_profile: profile) }
  let(:ticket_type) { create(:ticket_type, event: event, quantity_available: 5) }
  let(:entry) do
    GuestListEntry.create!(
      event: event,
      ticket_type: ticket_type,
      guest_name: "Community Guest",
      guest_email: "guest@example.com",
      quantity: 2,
      added_by: user.email
    )
  end

  before do
    allow(EmailService).to receive(:send_order_confirmation_async)
    allow(EmailService).to receive(:send_ticket_email_async)
  end

  it "issues a complimentary immutable ledger order and consumes central inventory" do
    post "/api/v1/organizer/events/#{event.id}/guest_list/#{entry.id}/redeem", headers: auth_headers(user)

    expect(response).to have_http_status(:ok)
    order = entry.reload.order
    expect(order).to be_completed
    expect(order.source).to eq("guest_list")
    expect(order.total_cents).to eq(0)
    expect(order.order_items.first).to have_attributes(unit_price_cents: 0, quantity: 2, subtotal_cents: 0)
    expect(order.tickets.count).to eq(2)
    expect(ticket_type.reload.quantity_sold).to eq(2)
  end
end
