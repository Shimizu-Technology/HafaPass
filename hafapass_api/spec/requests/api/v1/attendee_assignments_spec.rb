# frozen_string_literal: true

require "rails_helper"
require "ostruct"

RSpec.describe "Per-ticket attendee details and scoped registration questions", type: :request do
  let(:profile) { create(:organizer_profile, :verified) }
  let(:org) { profile.organization }
  let!(:event) do
    create(:event, :published, organizer_profile: profile, organization: org, title: "FD Alumni Tournament",
      max_capacity: 200, starts_at: 5.days.from_now, ends_at: 5.days.from_now + 4.hours)
  end
  let!(:adult) { create(:ticket_type, event: event, name: "Adult GA", price_cents: 1500, quantity_available: 50) }
  let!(:alumni) do
    create(:ticket_type, event: event, name: "Free Alumni", price_cents: 0, quantity_available: 50,
      max_per_buyer: nil, attendee_info_mode: "name_only")
  end
  let!(:graduation_year) do
    create(:registration_question, event: event, prompt: "Graduation Year", kind: :number, scope: :ticket,
      required: true, ticket_type_ids: [alumni.id], show_on_scanner: true, help_text: "4-digit year",
      validation_rules: { "min" => 1950, "max" => 2035 })
  end
  let!(:division) do
    create(:registration_question, event: event, prompt: "Division", kind: :selection, required: true,
      options: %w[Maroon Gold], ticket_type_ids: [alumni.id])
  end

  before do
    allow(EmailService).to receive(:send_order_confirmation_async)
    allow(EmailService).to receive(:send_ticket_email_async)
    allow(StripeService).to receive(:payment_enabled?).and_return(true)
    allow(StripeService).to receive(:create_payment_intent) do |order, **|
      OpenStruct.new(id: "pi_attendees_#{order.id}", client_secret: "cs_attendees_#{order.id}",
        allowed_payment_method_types: ["card"], payment_method_types: ["card"])
    end
  end

  def alumni_assignments(years: [1998, 2004])
    [
      { ticket_type_id: alumni.id, index: 0, attendee_name: " Maria  Cruz ", registration_answers: { graduation_year.id.to_s => years[0] } },
      { ticket_type_id: alumni.id, index: 1, attendee_name: "Jesse Perez", registration_answers: { graduation_year.id.to_s => years[1] } }
    ]
  end

  def checkout(line_items:, assignments: alumni_assignments, answers: { division.id.to_s => "Maroon" })
    post "/api/v1/orders", params: {
      event_id: event.id, buyer_email: "Buyer@Example.com", buyer_name: "Pat Buyer", terms_accepted: true,
      terms_version: PolicyRegistry.buyer_terms[:version], line_items: line_items,
      registration_answers: answers, attendee_assignments: assignments
    }.to_json, headers: { "Content-Type" => "application/json" }
  end

  def post_stripe_event(type, object)
    post "/webhooks/stripe", params: { id: "evt_#{SecureRandom.hex(4)}", type: type, data: { object: object } }.to_json,
      headers: { "Content-Type" => "application/json" }
  end

  it "completes a mixed paid + free alumni cart via webhook with each ticket's attendee and ticket-scoped answers" do
    checkout(line_items: [{ ticket_type_id: adult.id, quantity: 2 }, { ticket_type_id: alumni.id, quantity: 2 }])
    expect(response).to have_http_status(:created)
    order = Order.find(response.parsed_body.fetch("id"))
    expect(order).to be_pending
    expect(order.tickets).to be_empty
    expect(order.order_items.find_by(ticket_type: adult).metadata).to eq({})
    stored = order.order_items.find_by(ticket_type: alumni).metadata.fetch("attendees")
    expect(stored.map { |attendee| attendee["attendee_name"] }).to eq(["Maria Cruz", "Jesse Perez"])
    expect(order.registration_responses.order_scoped.sole).to have_attributes(prompt_snapshot: "Division",
      answer: { "value" => "Maroon" })

    payment = order.payments.sole
    post_stripe_event("payment_intent.succeeded", { id: payment.provider_payment_id, amount: payment.amount_cents,
      amount_received: payment.amount_cents, currency: "usd", status: "succeeded" })
    expect(response).to have_http_status(:ok)

    order.reload
    expect(order).to be_completed
    adult_tickets = order.tickets.where(ticket_type: adult).order(:id)
    alumni_tickets = order.tickets.where(ticket_type: alumni).order(:id)
    expect(adult_tickets.map(&:attendee_name)).to eq(["Pat Buyer", "Pat Buyer"])
    expect(alumni_tickets.map { |ticket| [ticket.attendee_name, ticket.attendee_email, ticket.holder_email] }).to eq([
      ["Maria Cruz", "Buyer@Example.com", "buyer@example.com"], ["Jesse Perez", "Buyer@Example.com", "buyer@example.com"]
    ])
    expect(alumni_tickets.map { |ticket| ticket.registration_responses.sole.answer["value"] }).to eq([1998, 2004])
    expect(alumni_tickets.first.registration_responses.sole).to have_attributes(
      order_id: order.id, prompt_snapshot: "Graduation Year", kind_snapshot: RegistrationQuestion.kinds.fetch("number"),
      required_snapshot: true
    )
    expect(adult_tickets.flat_map(&:registration_responses)).to be_empty

    # Issuance is idempotent: re-running it never duplicates per-ticket answers.
    expect { Commerce::OrderLifecycle.send(:issue_tickets!, order) }.not_to change(RegistrationResponse, :count)
  end

  it "keeps a regular adult-only checkout free of alumni questions and attendee details" do
    checkout(line_items: [{ ticket_type_id: adult.id, quantity: 2 }], assignments: [], answers: {})

    expect(response).to have_http_status(:created)
    order = Order.find(response.parsed_body.fetch("id"))
    expect(order.registration_responses).to be_empty
    expect(order.order_items.sole.metadata).to eq({})
  end

  it "rejects missing attendee names, out-of-range years and details for tickets not in the cart" do
    line_items = [{ ticket_type_id: alumni.id, quantity: 2 }]

    missing_name = alumni_assignments
    missing_name[1][:attendee_name] = " "
    checkout(line_items: line_items, assignments: missing_name)
    expect(response).to have_http_status(:unprocessable_entity)
    expect(response.parsed_body["error"]).to eq("Enter the attendee's full name for Free Alumni ticket #2")

    checkout(line_items: line_items, assignments: alumni_assignments(years: [1998, 1949]))
    expect(response).to have_http_status(:unprocessable_entity)
    expect(response.parsed_body["error"]).to eq("Invalid answer for Graduation Year (Free Alumni ticket #2)")

    checkout(line_items: line_items, assignments: alumni_assignments.first(1))
    expect(response).to have_http_status(:unprocessable_entity)
    expect(response.parsed_body["error"]).to match(/attendee's full name for Free Alumni ticket #2/)

    checkout(line_items: line_items, assignments: alumni_assignments + [{ ticket_type_id: alumni.id, index: 2, attendee_name: "Extra" }])
    expect(response).to have_http_status(:unprocessable_entity)
    expect(response.parsed_body["error"]).to eq("Attendee details do not match the tickets in this order")

    checkout(line_items: line_items, answers: {})
    expect(response).to have_http_status(:unprocessable_entity)
    expect(response.parsed_body["error"]).to eq("Invalid answer for Division")
    expect(event.orders).to be_empty
  end

  it "copies a name-and-email attendee onto every night ticket of a multi-night pass" do
    night = create(:event, :published, organizer_profile: profile, organization: org, title: "Night 1",
      max_capacity: 20, starts_at: 5.days.from_now, ends_at: 5.days.from_now + 3.hours)
    pass = create(:ticket_type, event: event, name: "Tournament Pass", price_cents: 4000, quantity_available: 10,
      attendee_info_mode: "name_and_email")
    TicketTypeIncludedEvent.create!(ticket_type: pass, included_event: night, position: 0)
    pass.update_column(:is_pass, true)

    checkout(line_items: [{ ticket_type_id: pass.id, quantity: 1 }], answers: {}, assignments: [
      { ticket_type_id: pass.id, index: 0, attendee_name: "Ana Taitano", attendee_email: "ANA@example.com" }
    ])
    expect(response).to have_http_status(:created)
    order = Order.find(response.parsed_body.fetch("id"))
    payment = order.payments.sole
    post_stripe_event("payment_intent.succeeded", { id: payment.provider_payment_id, amount: payment.amount_cents,
      amount_received: payment.amount_cents, currency: "usd", status: "succeeded" })

    parent = order.reload.tickets.find_by(parent_ticket_id: nil)
    child = parent.child_tickets.sole
    expect([parent, child].map { |ticket| [ticket.attendee_name, ticket.attendee_email] })
      .to eq([["Ana Taitano", "ana@example.com"], ["Ana Taitano", "ana@example.com"]])
    expect(child.event_id).to eq(night.id)

    checkout(line_items: [{ ticket_type_id: pass.id, quantity: 1 }], answers: {}, assignments: [
      { ticket_type_id: pass.id, index: 0, attendee_name: "Ana Taitano", attendee_email: "not-an-email" }
    ])
    expect(response.parsed_body["error"]).to eq("Enter a valid attendee email for Tournament Pass ticket #1")
  end

  it "lets trusted staff sales leave attendee details for the buyer's name" do
    result = Commerce::OrderCreator.call(
      event: event, line_items: [{ ticket_type_id: alumni.id, quantity: 1 }],
      buyer_email: "walkin@example.com", buyer_name: "Walk-in", registration_answers: { division.id.to_s => "Gold" },
      payment_required: false, service_fee: false, source: "box_office", payment_method: "door_cash"
    )

    ticket = result.order.tickets.sole
    expect(ticket.attendee_name).to eq("Walk-in")
    expect(ticket.registration_responses).to be_empty
  end

  it "skips an answer whose question was deleted between checkout and payment" do
    checkout(line_items: [{ ticket_type_id: alumni.id, quantity: 2 }])
    order = Order.find(response.parsed_body.fetch("id"))
    expect(order).to be_completed
    expect(order.tickets.map { |ticket| ticket.registration_responses.count }).to eq([1, 1])

    other_question = create(:registration_question, event: event, prompt: "Jersey", kind: :short_text, scope: :ticket,
      required: false, ticket_type_ids: [alumni.id])
    checkout(line_items: [{ ticket_type_id: alumni.id, quantity: 1 }, { ticket_type_id: adult.id, quantity: 1 }],
      assignments: [{ ticket_type_id: alumni.id, index: 0, attendee_name: "Late Answer",
        registration_answers: { graduation_year.id.to_s => 2001, other_question.id.to_s => "No. 7" } }])
    pending = Order.find(response.parsed_body.fetch("id"))
    expect(pending).to be_pending
    other_question.destroy!

    payment = pending.payments.sole
    post_stripe_event("payment_intent.succeeded", { id: payment.provider_payment_id, amount: payment.amount_cents,
      amount_received: payment.amount_cents, currency: "usd", status: "succeeded" })
    ticket = pending.reload.tickets.find_by(ticket_type: alumni)
    expect(pending).to be_completed
    expect(ticket.registration_responses.map(&:prompt_snapshot)).to eq(["Graduation Year"])
  end
end
