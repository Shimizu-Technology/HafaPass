# frozen_string_literal: true

require "rails_helper"
require "ostruct"
require "csv"

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
      validation_rules: { "min" => 1950, "max" => 2035, "integer" => true })
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

  def pending_alumni_checkout(extra_answers = {})
    checkout(line_items: [{ ticket_type_id: alumni.id, quantity: 1 }, { ticket_type_id: adult.id, quantity: 1 }],
      assignments: [{ ticket_type_id: alumni.id, index: 0, attendee_name: "Late Answer",
        registration_answers: { graduation_year.id.to_s => 2001 }.merge(extra_answers) }])
    Order.find(response.parsed_body.fetch("id")).tap { |order| expect(order).to be_pending }
  end

  def pay!(order)
    payment = order.payments.sole
    post_stripe_event("payment_intent.succeeded", { id: payment.provider_payment_id, amount: payment.amount_cents,
      amount_received: payment.amount_cents, currency: "usd", status: "succeeded" })
  end

  it "refuses to delete a question whose answers wait on a pending payment, then records them on payment" do
    jersey = create(:registration_question, event: event, prompt: "Jersey", kind: :short_text, scope: :ticket,
      required: false, ticket_type_ids: [alumni.id])
    pending = pending_alumni_checkout(jersey.id.to_s => "No. 7")

    delete "/api/v1/organizer/events/#{event.id}/registration_questions/#{jersey.id}", headers: auth_headers(profile.user)
    expect(response).to have_http_status(:unprocessable_entity)
    expect(response.parsed_body["errors"].join).to include("Pause the question instead")
    expect(RegistrationQuestion.exists?(jersey.id)).to be(true)

    pay!(pending)
    ticket = pending.reload.tickets.find_by(ticket_type: alumni)
    expect(pending).to be_completed
    expect(ticket.registration_responses.map { |answer| [answer.prompt_snapshot, answer.answer["value"]] })
      .to contain_exactly(["Graduation Year", 2001], ["Jersey", "No. 7"])

    jersey.update!(active: false)
    delete "/api/v1/organizer/events/#{event.id}/registration_questions/#{create(:registration_question, event: event).id}",
      headers: auth_headers(profile.user)
    expect(response).to have_http_status(:no_content)
  end

  it "still issues tickets, keeps the accepted snapshot and reports it when a question vanishes outside the app" do
    jersey = create(:registration_question, event: event, prompt: "Jersey", kind: :short_text, scope: :ticket,
      required: false, ticket_type_ids: [alumni.id])
    pending = pending_alumni_checkout(jersey.id.to_s => "No. 7")
    allow(Sentry).to receive(:capture_message)
    RegistrationQuestion.where(id: jersey.id).delete_all

    pay!(pending)
    ticket = pending.reload.tickets.find_by(ticket_type: alumni)
    expect(pending).to be_completed
    expect(ticket.attendee_name).to eq("Late Answer")
    expect(ticket.registration_responses.map(&:prompt_snapshot)).to eq(["Graduation Year"])
    snapshot = pending.order_items.find_by(ticket_type: alumni).metadata.dig("attendees", 0, "answers")
    expect(snapshot).to include(include("question_id" => jersey.id, "prompt" => "Jersey", "value" => "No. 7"))
    expect(Sentry).to have_received(:capture_message).with(/deleted before order #{pending.id} was paid/, level: :warning)
  end

  # Called directly with parsed-JSON values: the public endpoint's per-network
  # checkout cap would otherwise throttle this many attempts.
  def buyer_checkout(assignments: alumni_assignments, answers: { division.id.to_s => "Maroon" })
    Commerce::OrderCreator.call(event: event, line_items: [{ "ticket_type_id" => alumni.id, "quantity" => 2 }],
      buyer_email: "buyer@example.com", buyer_name: "Pat Buyer", payment_required: false,
      require_registration_answers: true, registration_answers: answers, attendee_assignments: assignments)
  end

  it "rejects non-text attendee names, untrimmed or non-text choices and fractional graduation years" do
    [true, ["Maria"], { "first" => "Maria" }].each do |bad_name|
      bad = alumni_assignments
      bad[0][:attendee_name] = bad_name
      expect { buyer_checkout(assignments: bad) }
        .to raise_error(Commerce::OrderCreator::CheckoutError, "The attendee details for Free Alumni ticket #1 must be text")
    end

    [" Maroon", ["Maroon"], 1].each do |bad_choice|
      expect { buyer_checkout(answers: { division.id.to_s => bad_choice }) }
        .to raise_error(Commerce::OrderCreator::CheckoutError, "Invalid answer for Division")
    end

    [1998.5, "1998.5", "1" * 30].each do |bad_year|
      expect { buyer_checkout(assignments: alumni_assignments(years: [bad_year, 2004])) }
        .to raise_error(Commerce::OrderCreator::CheckoutError, "Invalid answer for Graduation Year (Free Alumni ticket #1)")
    end
    expect(event.orders).to be_empty
    expect(buyer_checkout.order.tickets.map(&:attendee_name)).to contain_exactly("Maria Cruz", "Jesse Perez")
  end

  it "exports a paid pass's per-ticket and order answers from an included night" do
    night = create(:event, :published, organizer_profile: profile, organization: org, title: "Night 1",
      max_capacity: 20, starts_at: 5.days.from_now, ends_at: 5.days.from_now + 3.hours)
    pass = create(:ticket_type, event: event, name: "Tournament Pass", price_cents: 4000, quantity_available: 10,
      attendee_info_mode: "name_only")
    TicketTypeIncludedEvent.create!(ticket_type: pass, included_event: night, position: 0)
    pass.update_column(:is_pass, true)
    jersey = create(:registration_question, event: event, prompt: "Jersey Number", kind: :short_text, scope: :ticket,
      required: true, ticket_type_ids: [pass.id], position: 5)
    contact = create(:registration_question, event: event, prompt: "Emergency Contact", kind: :short_text,
      required: true, ticket_type_ids: [pass.id], position: 6)

    checkout(line_items: [{ ticket_type_id: pass.id, quantity: 2 }], answers: { contact.id.to_s => "Rosa 671-555-0101" },
      assignments: [
        { ticket_type_id: pass.id, index: 0, attendee_name: "Ana Taitano", registration_answers: { jersey.id.to_s => "12" } },
        { ticket_type_id: pass.id, index: 1, attendee_name: "Ben Cruz", registration_answers: { jersey.id.to_s => "33" } }
      ])
    order = Order.find(response.parsed_body.fetch("id"))
    pay!(order)
    expect(order.reload).to be_completed
    child = order.tickets.find_by(event: night, attendee_name: "Ben Cruz")
    expect(child.effective_registration_responses.map(&:prompt_snapshot)).to contain_exactly("Jersey Number", "Emergency Contact")

    post "/api/v1/organizer/events/#{night.id}/sales_exports", params: { view: "tickets", expand_questions: true,
      payment_environment: "test", columns: %w[name notes_custom_answers] }, headers: auth_headers(profile.user)
    expect(response).to have_http_status(:ok)
    csv = CSV.parse(response.body.delete_prefix("\uFEFF"), headers: true)
    expect(csv.headers).to include("Jersey Number", "Emergency Contact")
    rows = csv.index_by { |row| row["Name"] }
    expect(rows["Ben Cruz"]["Jersey Number"]).to eq("33")
    expect(rows["Ana Taitano"]["Jersey Number"]).to eq("12")
    expect(rows["Ben Cruz"]["Emergency Contact"]).to eq("Rosa 671-555-0101")
    expect(rows["Ben Cruz"].fields.last(3).first).to include("Jersey Number: 33").and include("Emergency Contact: Rosa")
  end
end
