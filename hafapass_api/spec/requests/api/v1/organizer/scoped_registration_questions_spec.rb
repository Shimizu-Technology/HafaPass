# frozen_string_literal: true

require "rails_helper"
require "csv"

RSpec.describe "Organizer scoped registration questions and attendee info", type: :request do
  let(:profile) { create(:organizer_profile) }
  let(:user) { profile.user }
  let(:event) { create(:event, :published, organizer_profile: profile) }
  let(:headers) { auth_headers(user) }
  let(:base) { "/api/v1/organizer/events/#{event.id}" }
  let!(:adult) { create(:ticket_type, event: event, name: "Adult GA") }
  let!(:alumni) { create(:ticket_type, event: event, name: "Free Alumni", price_cents: 0) }

  it "creates, edits and lists questions with scope, ticket types, help text and number limits" do
    post "#{base}/registration_questions", params: {
      prompt: "Graduation Year", kind: "number", required: true, scope: "ticket", ticket_type_ids: [alumni.id],
      show_on_scanner: true, help_text: "4-digit year", validation_rules: { min: 1950, max: 2035 }
    }, headers: headers, as: :json
    expect(response).to have_http_status(:created)
    expect(response.parsed_body).to include("kind" => "number", "scope" => "ticket", "ticket_type_ids" => [alumni.id],
      "show_on_scanner" => true, "help_text" => "4-digit year", "validation_rules" => { "min" => 1950, "max" => 2035 })
    question_id = response.parsed_body["id"]

    patch "#{base}/registration_questions/#{question_id}", params: { scope: "order", ticket_type_ids: [],
      validation_rules: { min: 1960 } }, headers: headers, as: :json
    expect(response).to have_http_status(:ok)
    expect(response.parsed_body).to include("scope" => "order", "ticket_type_ids" => [], "validation_rules" => { "min" => 1960 })

    post "#{base}/registration_questions", params: { prompt: "Sizes", kind: "multi_select", options: %w[S M L] },
      headers: headers, as: :json
    expect(response).to have_http_status(:created)

    get "#{base}/registration_questions", headers: headers
    expect(response.parsed_body["registration_questions"].map { |item| item["kind"] }).to eq(%w[number multi_select])

    get "/api/v1/events/#{event.slug}"
    public_question = response.parsed_body["registration_questions"].find { |item| item["id"] == question_id }
    expect(public_question).to include("scope" => "order", "help_text" => "4-digit year", "show_on_scanner" => true,
      "validation_rules" => { "min" => 1960 })
    expect(response.parsed_body["ticket_types"].map { |type| type["attendee_info_mode"] }).to all(eq("none"))
  end

  it "rejects cross-event ticket types, missing choices, bad limits and unknown kinds" do
    other_type = create(:ticket_type, event: create(:event, :published))

    post "#{base}/registration_questions", params: { prompt: "Year", kind: "short_text", ticket_type_ids: [other_type.id] },
      headers: headers, as: :json
    expect(response).to have_http_status(:unprocessable_entity)
    expect(response.parsed_body["errors"]).to include("Ticket type ids must belong to this event")

    post "#{base}/registration_questions", params: { prompt: "Sizes", kind: "multi_select" }, headers: headers, as: :json
    expect(response.parsed_body["errors"]).to include("Options must include at least one choice")

    post "#{base}/registration_questions", params: { prompt: "Year", kind: "number", validation_rules: { min: 2035, max: 1950 } },
      headers: headers, as: :json
    expect(response.parsed_body["errors"]).to include("Validation rules min must not be greater than max")

    post "#{base}/registration_questions", params: { prompt: "Name", kind: "short_text", validation_rules: { min: 1 } },
      headers: headers, as: :json
    expect(response.parsed_body["errors"]).to include("Validation rules are only supported for number questions")

    post "#{base}/registration_questions", params: { prompt: "Weird", kind: "date" }, headers: headers, as: :json
    expect(response).to have_http_status(:unprocessable_entity)
    expect(event.registration_questions).to be_empty
  end

  it "sets attendee info mode on ticket types and keeps max per buyer optional" do
    patch "#{base}/ticket_types/#{alumni.id}", params: { attendee_info_mode: "name_and_email", max_per_buyer: nil },
      headers: headers, as: :json
    expect(response).to have_http_status(:ok)
    expect(response.parsed_body).to include("attendee_info_mode" => "name_and_email", "max_per_buyer" => nil)

    patch "#{base}/ticket_types/#{alumni.id}", params: { attendee_info_mode: "everyone" }, headers: headers, as: :json
    expect(response).to have_http_status(:unprocessable_entity)
    expect(alumni.reload.attendee_info_mode).to eq("name_and_email")
  end

  def apply_template(template, ticket_type: nil, as_headers: headers)
    post "#{base}/registration_questions/apply_template",
      params: { template: template, ticket_type_id: ticket_type&.id }.compact, headers: as_headers, as: :json
  end

  it "applies one-click templates once and turns on attendee names for alumni door verification" do
    apply_template("fd_team_registration")
    expect(response).to have_http_status(:created)
    expect(response.parsed_body["registration_questions"].map { |item| [item["prompt"], item["kind"], item["required"]] }).to eq([
      ["Class Name", "short_text", true], ["Graduation Year", "number", true], ["Division", "selection", false],
      ["Team Captain Phone", "phone", false]
    ])
    expect(event.registration_questions.find_by(prompt: "Division").options).to eq(%w[Maroon Gold Platinum Special])
    expect(event.registration_questions.find_by(prompt: "Graduation Year").validation_rules)
      .to eq("min" => 1950, "max" => 2035, "integer" => true)

    apply_template("fd_team_registration")
    expect(response.parsed_body).to include("registration_questions" => [], "updated_questions" => [],
      "skipped_prompts" => ["Class Name", "Graduation Year", "Division", "Team Captain Phone"])

    apply_template("alumni_door_verification", ticket_type: alumni)
    expect(response).to have_http_status(:created)
    door = event.registration_questions.find_by(prompt: "Graduation Year", scope: :ticket)
    expect(door).to have_attributes(show_on_scanner: true, ticket_type_ids: [alumni.id], required: true)
    expect(response.parsed_body["ticket_type"]).to eq("id" => alumni.id, "attendee_info_mode" => "name_only")
    expect(alumni.reload.attendee_info_mode).to eq("name_only")
    expect(event.registration_questions.order(:position).pluck(:position)).to eq([0, 1, 2, 3, 4])

    apply_template("merch_shirt_size")
    expect(event.registration_questions.find_by(prompt: "Shirt Size").options).to eq(%w[S M L XL 2XL])

    apply_template("unknown")
    expect(response).to have_http_status(:unprocessable_entity)
  end

  it "requires a ticket type for alumni door verification and extends it to a second ticket type" do
    apply_template("alumni_door_verification")
    expect(response).to have_http_status(:unprocessable_entity)
    expect(response.parsed_body["error"]).to eq("Choose the ticket type this template is for")
    expect(event.registration_questions).to be_empty

    student = create(:ticket_type, event: event, name: "FD Student", price_cents: 0)
    apply_template("alumni_door_verification", ticket_type: alumni)
    apply_template("alumni_door_verification", ticket_type: student)
    expect(response).to have_http_status(:created)
    expect(response.parsed_body["updated_questions"].sole).to include("prompt" => "Graduation Year",
      "ticket_type_ids" => [alumni.id, student.id])
    expect(event.registration_questions.where(prompt: "Graduation Year", scope: :ticket).sole.ticket_type_ids)
      .to eq([alumni.id, student.id])
    expect([alumni.reload, student.reload].map(&:attendee_info_mode)).to eq(%w[name_only name_only])

    apply_template("alumni_door_verification", ticket_type: student)
    expect(response.parsed_body["skipped_prompts"]).to eq(["Graduation Year"])
  end

  it "returns a conflict without changes when an existing question cannot be combined with the template" do
    create(:registration_question, event: event, prompt: "Shirt size", kind: :short_text, required: false)
    apply_template("merch_shirt_size")
    expect(response).to have_http_status(:conflict)
    expect(response.parsed_body["error"]).to include('"Shirt Size" already exists with a different answer type')

    create(:registration_question, event: event, prompt: "Class Name", kind: :short_text, required: true,
      ticket_type_ids: [adult.id])
    apply_template("fd_team_registration")
    expect(response).to have_http_status(:conflict)
    expect(response.parsed_body["error"]).to include('"Class Name" is already limited to specific ticket types')
    expect(event.registration_questions.pluck(:prompt)).to contain_exactly("Shirt size", "Class Name")
  end

  it "never downgrades a ticket type that was upgraded to name and email while the template waited for its lock" do
    allow_any_instance_of(TicketType).to receive(:lock!).and_wrap_original do |original, *arguments|
      TicketType.where(id: original.receiver.id).update_all(attendee_info_mode: "name_and_email")
      original.call(*arguments)
    end

    apply_template("alumni_door_verification", ticket_type: alumni)
    expect(response).to have_http_status(:created)
    expect(response.parsed_body["ticket_type"]["attendee_info_mode"]).to eq("name_and_email")
    expect(alumni.reload.attendee_info_mode).to eq("name_and_email")
  end

  it "leaves questions and the ticket type untouched when alumni door verification lacks inventory access" do
    marketer = create(:user)
    create(:organization_membership, organization: event.organization, user: marketer, role: "marketer", status: "active")
    allow(OrganizationAuthorization).to receive(:allowed?).and_call_original
    allow(OrganizationAuthorization).to receive(:allowed?).with(hash_including(user: marketer, permission: :manage_events))
      .and_return(true)

    marketer_headers = auth_headers(marketer).merge("X-Organization-Id" => event.organization_id.to_s)
    apply_template("merch_shirt_size", as_headers: marketer_headers)
    expect(response).to have_http_status(:created)

    apply_template("alumni_door_verification", ticket_type: alumni, as_headers: marketer_headers)
    expect(response).to have_http_status(:forbidden)
    expect(event.registration_questions.pluck(:prompt)).to eq(["Shirt Size"])
    expect(alumni.reload.attendee_info_mode).to eq("none")
  end

  it "rejects malformed ticket type lists instead of widening a question to every ticket type" do
    [["abc"], [{ id: alumni.id }], [0], "all", [alumni.id, "x"]].each do |bad|
      post "#{base}/registration_questions", params: { prompt: "Year", kind: "short_text", ticket_type_ids: bad },
        headers: headers, as: :json
      expect(response).to have_http_status(:unprocessable_entity), bad.inspect
      expect(response.parsed_body["errors"]).to include("Ticket type ids must be a list of ticket types")
    end
    post "#{base}/registration_questions", params: { prompt: "Year", kind: "short_text", ticket_type_ids: [alumni.id.to_s] },
      headers: headers, as: :json
    expect(response.parsed_body["ticket_type_ids"]).to eq([alumni.id])
    expect(event.registration_questions.count).to eq(1)
  end

  it "exports multi-select and per-ticket answers on ticket and order rows" do
    sizes = create(:registration_question, event: event, prompt: "Sizes", kind: :multi_select, options: %w[S M L],
      required: false, position: 0)
    year = create(:registration_question, event: event, prompt: "Graduation Year", kind: :number, scope: :ticket,
      required: false, position: 1, ticket_type_ids: [alumni.id])
    order = create(:order, event: event, buyer_name: "Pat Buyer", buyer_email: "pat@example.test", completed_at: Time.current)
    item = create(:order_item, order: order, ticket_type: alumni, quantity: 2, unit_price_cents: 0, subtotal_cents: 0,
      organizer_proceeds_cents: 0)
    first = create(:ticket, event: event, order: order, order_item: item, ticket_type: alumni, attendee_name: "Maria Cruz")
    second = create(:ticket, event: event, order: order, order_item: item, ticket_type: alumni, attendee_name: "Jesse Perez")
    RegistrationResponse.create!(order: order, registration_question: sizes, prompt_snapshot: "Sizes",
      kind_snapshot: 7, options_snapshot: %w[S M L], answered_at: Time.current, answer: { "value" => %w[S L] })
    [[first, 1998], [second, 2004]].each do |ticket, value|
      RegistrationResponse.create!(order: order, ticket: ticket, registration_question: year, prompt_snapshot: "Graduation Year",
        kind_snapshot: 4, answered_at: Time.current, answer: { "value" => value })
    end

    post "#{base}/sales_exports", params: { view: "orders", expand_questions: true,
      columns: %w[order_number name notes_custom_answers] }, headers: headers
    expect(response).to have_http_status(:ok)
    row = CSV.parse(response.body.delete_prefix("﻿"), headers: true).sole
    expect(row["Sizes"]).to eq("S, L")
    expect(row["Graduation Year"]).to eq("1998; 2004")
    expect(row.fields.last(3).first).to include("Graduation Year (HP-T#{first.id}): 1998")

    post "#{base}/sales_exports", params: { view: "tickets", expand_questions: true,
      columns: %w[name notes_custom_answers] }, headers: headers
    expect(response).to have_http_status(:ok)
    rows = CSV.parse(response.body.delete_prefix("﻿"), headers: true).index_by { |entry| entry["Name"] }
    expect(rows["Maria Cruz"]["Graduation Year"]).to eq("1998")
    expect(rows["Jesse Perez"]["Graduation Year"]).to eq("2004")
    expect(rows["Jesse Perez"]["Sizes"]).to eq("S, L")
  end
end
