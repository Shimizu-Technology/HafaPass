# frozen_string_literal: true

require "rails_helper"

# Required registration questions (for example the FD Team Registration
# template) are for buyers at online checkout. Staff selling at the door or
# redeeming a guest list must not be blocked by them.
RSpec.describe "Staff sales with required registration questions", type: :request do
  let(:user) { create(:user, :organizer) }
  let(:profile) { create(:organizer_profile, user: user) }
  let(:event) { create(:event, :published, organizer_profile: profile, starts_at: 3.days.from_now) }
  let!(:ticket_type) do
    create(:ticket_type, event: event, name: "Team Entry", price_cents: 2500, quantity_available: 50,
      attendee_info_mode: "name_only")
  end
  let(:headers) { auth_headers(user) }
  let(:base) { "/api/v1/organizer/events/#{event.id}" }
  let(:sale) do
    { line_items: [{ ticket_type_id: ticket_type.id, quantity: 2 }], buyer_name: "Walk-in Team",
      buyer_email: "team@example.com" }
  end

  before do
    allow(EmailService).to receive(:send_order_confirmation_async)
    allow(EmailService).to receive(:send_ticket_email_async)
    post "#{base}/registration_questions/apply_template", params: { template: "fd_team_registration" }, headers: headers, as: :json
    expect(response).to have_http_status(:created)
    create(:registration_question, event: event, prompt: "Jersey", kind: :short_text, scope: :ticket, required: true,
      ticket_type_ids: [ticket_type.id])
    expect(event.registration_questions.where(required: true).count).to eq(3)
  end

  it "completes a box office cash sale without the required answers" do
    post "#{base}/box_office", params: sale.merge(payment_method: "door_cash"), headers: headers

    expect(response).to have_http_status(:created)
    order = Order.find(response.parsed_body.fetch("id"))
    expect(order).to be_completed
    expect(order.tickets.map(&:attendee_name)).to eq(["Walk-in Team", "Walk-in Team"])
    expect(order.registration_responses).to be_empty
  end

  it "completes a card-present box office sale without the required answers" do
    create(:card_present_account, :verified, organization: event.organization)

    post "#{base}/box_office", params: sale.merge(payment_method: "door_card"),
      headers: headers.merge("Idempotency-Key" => "staff-required-questions")

    expect(response).to have_http_status(:created)
    expect(response.parsed_body).to include("status" => "completed", "payment_method" => "door_card")
    expect(Order.find(response.parsed_body.fetch("id")).tickets.count).to eq(2)
  end

  it "redeems a guest list entry without the required answers" do
    entry = GuestListEntry.create!(event: event, ticket_type: ticket_type, guest_name: "Coach Guest",
      guest_email: "coach@example.com", quantity: 1, added_by: user.email)

    post "#{base}/guest_list/#{entry.id}/redeem", headers: headers

    expect(response).to have_http_status(:ok)
    expect(entry.reload.order).to be_completed
    expect(entry.order.tickets.sole.attendee_name).to eq("Coach Guest")
  end

  describe "answers staff supply" do
    let(:year) { event.registration_questions.find_by(prompt: "Graduation Year") }

    it "rejects an invalid answer on a cash sale and keeps a valid one" do
      post "#{base}/box_office", params: sale.merge(payment_method: "door_cash", registration_answers: { year.id.to_s => 1800 }),
        headers: headers, as: :json
      expect(response).to have_http_status(:unprocessable_entity)
      expect(response.parsed_body["error"]).to eq("Invalid answer for Graduation Year")

      post "#{base}/box_office", params: sale.merge(payment_method: "door_cash", registration_answers: ["1998"]),
        headers: headers, as: :json
      expect(response).to have_http_status(:unprocessable_entity)
      expect(response.parsed_body["error"]).to eq("registration_answers must be an object")

      post "#{base}/box_office", params: sale.merge(payment_method: "door_cash", registration_answers: "1998"),
        headers: headers, as: :json
      expect(response).to have_http_status(:unprocessable_entity)
      expect(response.parsed_body["error"]).to eq("registration_answers must be an object")

      post "#{base}/box_office", params: sale.merge(payment_method: "door_cash", registration_answers: { year.id.to_s => 1998 }),
        headers: headers, as: :json
      expect(response).to have_http_status(:created)
      expect(Order.find(response.parsed_body.fetch("id")).registration_responses.sole.answer).to eq("value" => 1998)
    end

    it "rejects an invalid answer on a card-present sale before charging" do
      create(:card_present_account, :verified, organization: event.organization)

      expect do
        post "#{base}/box_office", params: sale.merge(payment_method: "door_card", registration_answers: { year.id.to_s => 1800 }),
          headers: headers.merge("Idempotency-Key" => "staff-invalid-answer"), as: :json
      end.not_to change(CardPresentPaymentAttempt, :count)
      expect(response).to have_http_status(:unprocessable_entity)
      expect(response.parsed_body["error"]).to eq("Invalid answer for Graduation Year")
    end

    it "rejects an invalid answer on guest list redemption and keeps a valid one" do
      entry = GuestListEntry.create!(event: event, ticket_type: ticket_type, guest_name: "Coach Guest",
        guest_email: "coach@example.com", quantity: 1, added_by: user.email)

      post "#{base}/guest_list/#{entry.id}/redeem", params: { registration_answers: { year.id.to_s => 1800 } }, headers: headers, as: :json
      expect(response).to have_http_status(:unprocessable_entity)
      expect(response.parsed_body["error"]).to eq("Invalid answer for Graduation Year")
      expect(entry.reload.order).to be_nil

      post "#{base}/guest_list/#{entry.id}/redeem", params: { registration_answers: { year.id.to_s => 2001 } }, headers: headers, as: :json
      expect(response).to have_http_status(:ok)
      expect(entry.reload.order.registration_responses.sole.answer).to eq("value" => 2001)
    end
  end

  it "still validates an answer that staff do supply" do
    year = event.registration_questions.find_by(prompt: "Graduation Year")

    expect do
      Commerce::OrderCreator.call(event: event, line_items: sale[:line_items], buyer_name: "Walk-in", buyer_email: "walkin@example.com",
        registration_answers: { year.id.to_s => 1800 }, payment_required: false, service_fee: false,
        source: "box_office", payment_method: "door_cash")
    end.to raise_error(Commerce::OrderCreator::CheckoutError, "Invalid answer for Graduation Year")

    result = Commerce::OrderCreator.call(event: event, line_items: sale[:line_items], buyer_name: "Walk-in",
      buyer_email: "walkin@example.com", registration_answers: { year.id.to_s => 1998 }, payment_required: false,
      service_fee: false, source: "box_office", payment_method: "door_cash")
    expect(result.order.registration_responses.sole.answer).to eq("value" => 1998)
  end
end
