require "rails_helper"

RSpec.describe "Api::V1::Orders", type: :request do
  let(:organizer_profile) { create(:organizer_profile) }
  let(:event) { create(:event, :published, organizer_profile: organizer_profile, starts_at: 5.days.from_now) }
  let!(:ga_ticket) { create(:ticket_type, event: event, name: "General Admission", price_cents: 2500, quantity_available: 100) }
  let!(:vip_ticket) { create(:ticket_type, :vip, event: event, price_cents: 7500, quantity_available: 20) }
  let(:json_headers) { { "Content-Type" => "application/json" } }

  # Helper for sending JSON POST requests
  def post_json(path, params:, headers: {})
    post path, params: params.to_json, headers: json_headers.merge(headers)
  end

  describe "POST /api/v1/orders" do
    let(:valid_params) do
      {
        event_id: event.id,
        buyer_email: "buyer@example.com",
        buyer_name: "Jane Smith",
        buyer_phone: "671-555-0100",
        terms_accepted: true,
        terms_version: PolicyRegistry.buyer_terms[:version],
        line_items: [
          { ticket_type_id: ga_ticket.id, quantity: 2 },
          { ticket_type_id: vip_ticket.id, quantity: 1 }
        ]
      }
    end

    context "with valid params" do
      it "creates an order with correct totals" do
        post_json "/api/v1/orders", params: valid_params

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
        post_json "/api/v1/orders", params: valid_params

        json = JSON.parse(response.body)
        expect(json["tickets"].length).to eq(3)
        expect(json["tickets"].map { |t| t["ticket_type"]["name"] }.sort)
          .to eq(["General Admission", "General Admission", "VIP"])
      end

      it "returns separate display and admission credentials to the creating buyer" do
        post_json "/api/v1/orders", params: valid_params

        json = JSON.parse(response.body)
        credentials = json["tickets"].map { |ticket| ticket["display_credential"] }
        scan_credentials = json["tickets"].map { |ticket| ticket["scan_credential"] }
        expect(credentials.uniq.length).to eq(3)
        expect(credentials).to all(be_present)
        expect(scan_credentials).to all(be_present)
        expect(scan_credentials).not_to match_array(credentials)
        expect(json["tickets"]).to all(satisfy { |ticket| !ticket.key?("qr_code") })
      end

      it "increments quantity_sold on ticket types" do
        post_json "/api/v1/orders", params: valid_params

        expect(ga_ticket.reload.quantity_sold).to eq(2)
        expect(vip_ticket.reload.quantity_sold).to eq(1)
      end

      it "sets attendee info from buyer info" do
        post_json "/api/v1/orders", params: valid_params

        json = JSON.parse(response.body)
        json["tickets"].each do |ticket|
          expect(ticket["attendee_name"]).to eq("Jane Smith")
          expect(ticket).not_to have_key("attendee_email")
        end
      end

      it "sets order to completed with completed_at" do
        post_json "/api/v1/orders", params: valid_params

        json = JSON.parse(response.body)
        expect(json["status"]).to eq("completed")
        expect(json["completed_at"]).not_to be_nil
      end

      it "works without authentication (guest checkout)" do
        post_json "/api/v1/orders", params: valid_params

        expect(response).to have_http_status(:created)
        order = Order.last
        expect(order.user_id).to be_nil
        expect(JSON.parse(response.body)["guest_access_token"]).to be_present
      end

      it "attaches user when authenticated" do
        user = create(:user)
        headers = auth_headers(user)

        post_json "/api/v1/orders", params: valid_params, headers: headers

        expect(response).to have_http_status(:created)
        order = Order.last
        expect(order.user_id).to eq(user.id)
      end
    end

    it "fails closed in production when event-specific pilot readiness is absent" do
      allow(Rails.env).to receive(:production?).and_return(true)
      allow(PolicyRegistry).to receive(:production_approved?).and_return(true)

      post_json "/api/v1/orders", params: valid_params

      expect(response).to have_http_status(:service_unavailable)
      expect(response.parsed_body.fetch("error")).to include("current pilot readiness approval")
      expect(Order.count).to eq(0)
    end

    it "fails closed in production when Gate F candidate validation is absent" do
      allow(Rails.env).to receive(:production?).and_return(true)
      allow(PolicyRegistry).to receive(:production_approved?).and_return(true)
      allow_any_instance_of(Event).to receive(:production_release_gate_status).and_return(:pilot_validation)

      post_json "/api/v1/orders", params: valid_params

      expect(response).to have_http_status(:service_unavailable)
      expect(response.parsed_body.fetch("error")).to include("current Gate F validation approval")
      expect(Order.count).to eq(0)
    end

    context "with insufficient inventory" do
      it "returns 422 when quantity exceeds available" do
        params = valid_params.merge(
          line_items: [{ ticket_type_id: ga_ticket.id, quantity: 101 }]
        )

        post_json "/api/v1/orders", params: params

        expect(response).to have_http_status(:unprocessable_entity)
        json = JSON.parse(response.body)
        expect(json["error"]).to include("Only 100 tickets available")
      end

      it "returns 422 when quantity exceeds max_per_order" do
        params = valid_params.merge(
          line_items: [{ ticket_type_id: vip_ticket.id, quantity: 5 }]
        )

        post_json "/api/v1/orders", params: params

        expect(response).to have_http_status(:unprocessable_entity)
        json = JSON.parse(response.body)
        expect(json["error"]).to include("Maximum")
      end

      it "returns 422 before sales start" do
        ga_ticket.update!(sales_start_at: 1.day.from_now)

        post_json "/api/v1/orders", params: valid_params.merge(
          line_items: [{ ticket_type_id: ga_ticket.id, quantity: 1 }]
        )

        expect(response).to have_http_status(:unprocessable_entity)
        expect(JSON.parse(response.body)["error"]).to include("not currently on sale")
      end

      it "returns 422 after sales end" do
        ga_ticket.update!(sales_end_at: 1.minute.ago)

        post_json "/api/v1/orders", params: valid_params.merge(
          line_items: [{ ticket_type_id: ga_ticket.id, quantity: 1 }]
        )

        expect(response).to have_http_status(:unprocessable_entity)
        expect(JSON.parse(response.body)["error"]).to include("not currently on sale")
      end

      it "combines duplicate line items before checking limits" do
        params = valid_params.merge(
          line_items: [
            { ticket_type_id: vip_ticket.id, quantity: 3 },
            { ticket_type_id: vip_ticket.id, quantity: 2 }
          ]
        )

        post_json "/api/v1/orders", params: params

        expect(response).to have_http_status(:unprocessable_entity)
        expect(JSON.parse(response.body)["error"]).to include("Maximum")
        expect(vip_ticket.reload.quantity_sold).to eq(0)
      end

      it "does not create order or tickets on validation failure" do
        params = valid_params.merge(
          line_items: [{ ticket_type_id: ga_ticket.id, quantity: 101 }]
        )

        expect { post_json "/api/v1/orders", params: params }
          .not_to change { [Order.count, Ticket.count] }
      end

      it "does not increment quantity_sold on failure" do
        params = valid_params.merge(
          line_items: [{ ticket_type_id: ga_ticket.id, quantity: 101 }]
        )

        post_json "/api/v1/orders", params: params

        expect(ga_ticket.reload.quantity_sold).to eq(0)
      end
    end

    context "with invalid params" do
      it "rejects checkout without a current buyer-terms acceptance" do
        post_json "/api/v1/orders", params: valid_params.merge(terms_version: "stale-version")

        expect(response).to have_http_status(:unprocessable_entity)
        expect(response.parsed_body["error"]).to include("current HafaPass buyer terms")
        expect(event.orders).to be_empty
      end

      it "returns 422 when buyer_email is missing" do
        params = valid_params.merge(buyer_email: nil)

        post_json "/api/v1/orders", params: params

        expect(response).to have_http_status(:unprocessable_entity)
        json = JSON.parse(response.body)
        expect(json["error"]).to include("buyer_email")
      end

      it "returns 422 when buyer_name is missing" do
        params = valid_params.merge(buyer_name: nil)

        post_json "/api/v1/orders", params: params

        expect(response).to have_http_status(:unprocessable_entity)
        json = JSON.parse(response.body)
        expect(json["error"]).to include("buyer_name")
      end

      it "returns 422 when line_items is missing" do
        params = valid_params.except(:line_items)

        post_json "/api/v1/orders", params: params

        expect(response).to have_http_status(:unprocessable_entity)
        json = JSON.parse(response.body)
        expect(json["error"]).to include("line_items")
      end

      it "returns 404 when event not found" do
        params = valid_params.merge(event_id: 99999)

        post_json "/api/v1/orders", params: params

        expect(response).to have_http_status(:not_found)
        json = JSON.parse(response.body)
        expect(json["error"]).to eq("Event not found")
      end

      it "returns 404 for draft events" do
        draft_event = create(:event, organizer_profile: organizer_profile)
        params = valid_params.merge(event_id: draft_event.id)

        post_json "/api/v1/orders", params: params

        expect(response).to have_http_status(:not_found)
      end

      it "returns 422 when ticket_type does not belong to event" do
        other_event = create(:event, :published, organizer_profile: organizer_profile, starts_at: 5.days.from_now)
        other_tt = create(:ticket_type, event: other_event)

        params = valid_params.merge(
          line_items: [{ ticket_type_id: other_tt.id, quantity: 1 }]
        )

        post_json "/api/v1/orders", params: params

        expect(response).to have_http_status(:unprocessable_entity)
        json = JSON.parse(response.body)
        expect(json["error"]).to include("not found for this event")
      end

      it "returns 422 when quantity is zero" do
        params = valid_params.merge(
          line_items: [{ ticket_type_id: ga_ticket.id, quantity: 0 }]
        )

        post_json "/api/v1/orders", params: params

        expect(response).to have_http_status(:unprocessable_entity)
        json = JSON.parse(response.body)
        expect(json["error"]).to include("greater than 0")
      end
    end

    context "with Stripe enabled" do
      before do
        allow(StripeService).to receive(:payment_enabled?).and_return(true)
        allow(StripeService).to receive(:payment_mode).and_return("test")
        allow(StripeService).to receive(:publishable_key).and_return("pk_test_123")
        allow(StripeService).to receive(:create_payment_intent).and_return(
          OpenStruct.new(id: "pi_test_123", client_secret: "pi_test_123_secret_abc")
        )
      end

      it "does not expose ticket QR codes before payment completes" do
        post_json "/api/v1/orders", params: valid_params

        expect(response).to have_http_status(:created)
        json = JSON.parse(response.body)
        expect(json["status"]).to eq("pending")
        expect(json["tickets"]).to eq([])
        expect(Order.last.tickets.pluck(:qr_code)).to all(be_nil)
      end
    end
  end

  describe "POST /api/v1/orders/:id/cancel" do
    it "does not reveal an order without buyer authorization" do
      order = create(:order, :pending, event: event)

      post "/api/v1/orders/#{order.id}/cancel"

      expect(response).to have_http_status(:not_found)
    end

    it "rejects a verified token without a Clerk subject instead of raising" do
      order = create(:order, :pending, event: event)
      allow(ClerkAuthenticator).to receive(:verify).with("blank_sub").and_return({
        "sub" => "",
        "email" => "blank@example.com"
      })

      expect do
        post "/api/v1/orders/#{order.id}/cancel", headers: { "Authorization" => "Bearer blank_sub" }
      end.not_to change { order.reload.status }

      expect(response).to have_http_status(:not_found)
    end

    it "allows a guest buyer with the order-specific access token to cancel" do
      order = create(:order, :pending, event: event, user: nil)
      token = GuestOrderAccess.issue!(order)

      post "/api/v1/orders/#{order.id}/cancel", headers: { "X-Guest-Order-Token" => token }

      expect(response).to have_http_status(:ok)
      expect(order.reload).to be_cancelled
    end

    it "does not allow one guest order token to access another order" do
      first_order = create(:order, :pending, event: event, user: nil)
      second_order = create(:order, :pending, event: event, user: nil)
      token = GuestOrderAccess.issue!(first_order)

      post "/api/v1/orders/#{second_order.id}/cancel", headers: { "X-Guest-Order-Token" => token }

      expect(response).to have_http_status(:not_found)
      expect(second_order.reload).to be_pending
    end

    it "allows the authenticated buyer to cancel a pending order" do
      user = create(:user)
      order = create(:order, :pending, event: event, user: user)
      ticket = create(:ticket, order: order, ticket_type: ga_ticket, event: event)
      ga_ticket.update!(quantity_sold: 1)

      post "/api/v1/orders/#{order.id}/cancel", headers: auth_headers(user)

      expect(response).to have_http_status(:ok)
      expect(order.reload).to be_cancelled
      expect(ticket.reload).to be_cancelled
      expect(ga_ticket.reload.quantity_sold).to eq(0)
    end

    it "does not allow a different user to cancel a pending order" do
      owner = create(:user)
      other_user = create(:user)
      order = create(:order, :pending, event: event, user: owner)

      post "/api/v1/orders/#{order.id}/cancel", headers: auth_headers(other_user)

      expect(response).to have_http_status(:not_found)
      expect(order.reload).to be_pending
    end
  end
end
