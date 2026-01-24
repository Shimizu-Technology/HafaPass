require "rails_helper"

RSpec.describe "Api::V1::Orders", type: :request do
  let(:organizer_profile) { create(:organizer_profile) }
  let(:event) { create(:event, :published, organizer_profile: organizer_profile, starts_at: 5.days.from_now) }
  let!(:ga_ticket) { create(:ticket_type, event: event, name: "General Admission", price_cents: 2500, quantity_available: 100) }
  let!(:vip_ticket) { create(:ticket_type, :vip, event: event, price_cents: 7500, quantity_available: 20) }

  describe "POST /api/v1/orders" do
    let(:valid_params) do
      {
        event_id: event.id,
        buyer_email: "buyer@example.com",
        buyer_name: "Jane Smith",
        buyer_phone: "671-555-0100",
        line_items: [
          { ticket_type_id: ga_ticket.id, quantity: 2 },
          { ticket_type_id: vip_ticket.id, quantity: 1 }
        ]
      }
    end

    context "with valid params" do
      it "creates an order with correct totals" do
        post "/api/v1/orders", params: valid_params

        expect(response).to have_http_status(:created)
        json = JSON.parse(response.body)

        # subtotal: 2*2500 + 1*7500 = 12500 cents
        expect(json["subtotal_cents"]).to eq(12500)
        # service_fee: (12500 * 0.03).round + (3 * 50) = 375 + 150 = 525 cents
        expect(json["service_fee_cents"]).to eq(525)
        # total: 12500 + 525 = 13025 cents
        expect(json["total_cents"]).to eq(13025)
        expect(json["status"]).to eq("completed")
        expect(json["buyer_email"]).to eq("buyer@example.com")
        expect(json["buyer_name"]).to eq("Jane Smith")
      end

      it "creates tickets for each line item" do
        post "/api/v1/orders", params: valid_params

        json = JSON.parse(response.body)
        expect(json["tickets"].length).to eq(3)
        expect(json["tickets"].map { |t| t["ticket_type"]["name"] }.sort)
          .to eq(["General Admission", "General Admission", "VIP"])
      end

      it "generates unique QR codes for each ticket" do
        post "/api/v1/orders", params: valid_params

        json = JSON.parse(response.body)
        qr_codes = json["tickets"].map { |t| t["qr_code"] }
        expect(qr_codes.uniq.length).to eq(3)
        qr_codes.each do |qr|
          expect(qr).to match(/\A[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\z/)
        end
      end

      it "increments quantity_sold on ticket types" do
        post "/api/v1/orders", params: valid_params

        expect(ga_ticket.reload.quantity_sold).to eq(2)
        expect(vip_ticket.reload.quantity_sold).to eq(1)
      end

      it "sets attendee info from buyer info" do
        post "/api/v1/orders", params: valid_params

        json = JSON.parse(response.body)
        json["tickets"].each do |ticket|
          expect(ticket["attendee_name"]).to eq("Jane Smith")
          expect(ticket["attendee_email"]).to eq("buyer@example.com")
        end
      end

      it "sets order to completed with completed_at" do
        post "/api/v1/orders", params: valid_params

        json = JSON.parse(response.body)
        expect(json["status"]).to eq("completed")
        expect(json["completed_at"]).not_to be_nil
      end

      it "works without authentication (guest checkout)" do
        post "/api/v1/orders", params: valid_params

        expect(response).to have_http_status(:created)
        order = Order.last
        expect(order.user_id).to be_nil
      end

      it "attaches user when authenticated" do
        user = create(:user)
        headers = auth_headers(user)

        post "/api/v1/orders", params: valid_params, headers: headers

        expect(response).to have_http_status(:created)
        order = Order.last
        expect(order.user_id).to eq(user.id)
      end
    end

    context "with insufficient inventory" do
      it "returns 422 when quantity exceeds available" do
        params = valid_params.merge(
          line_items: [{ ticket_type_id: ga_ticket.id, quantity: 101 }]
        )

        post "/api/v1/orders", params: params

        expect(response).to have_http_status(:unprocessable_entity)
        json = JSON.parse(response.body)
        expect(json["error"]).to include("Only 100 tickets available")
      end

      it "returns 422 when quantity exceeds max_per_order" do
        params = valid_params.merge(
          line_items: [{ ticket_type_id: vip_ticket.id, quantity: 5 }]
        )

        post "/api/v1/orders", params: params

        expect(response).to have_http_status(:unprocessable_entity)
        json = JSON.parse(response.body)
        expect(json["error"]).to include("Maximum")
      end

      it "does not create order or tickets on validation failure" do
        params = valid_params.merge(
          line_items: [{ ticket_type_id: ga_ticket.id, quantity: 101 }]
        )

        expect { post "/api/v1/orders", params: params }
          .not_to change { [Order.count, Ticket.count] }
      end

      it "does not increment quantity_sold on failure" do
        params = valid_params.merge(
          line_items: [{ ticket_type_id: ga_ticket.id, quantity: 101 }]
        )

        post "/api/v1/orders", params: params

        expect(ga_ticket.reload.quantity_sold).to eq(0)
      end
    end

    context "with invalid params" do
      it "returns 422 when buyer_email is missing" do
        params = valid_params.merge(buyer_email: nil)

        post "/api/v1/orders", params: params

        expect(response).to have_http_status(:unprocessable_entity)
        json = JSON.parse(response.body)
        expect(json["error"]).to include("buyer_email")
      end

      it "returns 422 when buyer_name is missing" do
        params = valid_params.merge(buyer_name: nil)

        post "/api/v1/orders", params: params

        expect(response).to have_http_status(:unprocessable_entity)
        json = JSON.parse(response.body)
        expect(json["error"]).to include("buyer_name")
      end

      it "returns 422 when line_items is missing" do
        params = valid_params.except(:line_items)

        post "/api/v1/orders", params: params

        expect(response).to have_http_status(:unprocessable_entity)
        json = JSON.parse(response.body)
        expect(json["error"]).to include("line_items")
      end

      it "returns 404 when event not found" do
        params = valid_params.merge(event_id: 99999)

        post "/api/v1/orders", params: params

        expect(response).to have_http_status(:not_found)
        json = JSON.parse(response.body)
        expect(json["error"]).to eq("Event not found")
      end

      it "returns 404 for draft events" do
        draft_event = create(:event, organizer_profile: organizer_profile)
        params = valid_params.merge(event_id: draft_event.id)

        post "/api/v1/orders", params: params

        expect(response).to have_http_status(:not_found)
      end

      it "returns 422 when ticket_type does not belong to event" do
        other_event = create(:event, :published, organizer_profile: organizer_profile, starts_at: 5.days.from_now)
        other_tt = create(:ticket_type, event: other_event)

        params = valid_params.merge(
          line_items: [{ ticket_type_id: other_tt.id, quantity: 1 }]
        )

        post "/api/v1/orders", params: params

        expect(response).to have_http_status(:unprocessable_entity)
        json = JSON.parse(response.body)
        expect(json["error"]).to include("not found for this event")
      end

      it "returns 422 when quantity is zero" do
        params = valid_params.merge(
          line_items: [{ ticket_type_id: ga_ticket.id, quantity: 0 }]
        )

        post "/api/v1/orders", params: params

        expect(response).to have_http_status(:unprocessable_entity)
        json = JSON.parse(response.body)
        expect(json["error"]).to include("greater than 0")
      end
    end
  end
end
