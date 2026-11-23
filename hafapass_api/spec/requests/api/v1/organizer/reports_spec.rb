# frozen_string_literal: true

require "rails_helper"
require "csv"

RSpec.describe Api::V1::Organizer::ReportsController, type: :request do
  let(:profile) { create(:organizer_profile) }
  let(:event) { create(:event, :published, organizer_profile: profile) }
  let(:type) { create(:ticket_type, event: event, name: "Alumni") }
  let(:headers) { organizer_headers(profile.user) }
  let(:base) { "/api/v1/organizer/events/#{event.id}" }
  let(:order) { create(:order, event: event, buyer_name: "Sample buyer", source: "box_office") }

  def organizer_headers(user)
    auth_headers(user).merge("X-Organization-Id" => event.organization_id.to_s)
  end

  def staff(role, assigned: false)
    create(:user).tap do |user|
      create(:organization_membership, organization: event.organization, user: user, role: role)
      create(:event_staff_assignment, event: event, user: user, role: role) if assigned
    end
  end

  def record(question, value, ticket: nil, purchase: order)
    RegistrationResponse.create!(order: purchase, ticket: ticket, registration_question: question,
      prompt_snapshot: question.prompt, kind_snapshot: RegistrationQuestion.kinds.fetch(question.kind),
      required_snapshot: false, options_snapshot: question.options, answered_at: Time.current, answer: { value: value })
  end

  it "returns all authorized report sections and only this event's series" do
    create(:ticket, order: order, ticket_type: type)
    membership = create(:event_series_membership, event: event, event_series: create(:event_series, organization: event.organization))
    create(:event_series, organization: event.organization)

    get "#{base}/reports", headers: headers
    expect(response).to have_http_status(:ok)
    expect(response.headers["Cache-Control"]).to include("no-store")
    expect(response.parsed_body).to include("summary", "sales_by_tier", "attendance", "demographics", "payout_series")
    expect(response.parsed_body["summary"]).to include("tickets_active" => 1, "gross_sales_cents" => order.subtotal_cents)
    expect(response.parsed_body["payout_series"]).to eq([{ "id" => membership.event_series_id, "name" => membership.event_series.name }])
  end

  it "filters attendees by a numeric, text, multi-select or checkbox answer and returns inline answers without sibling data" do
    first = create(:ticket, order: order, ticket_type: type, attendee_name: "Sample attendee one")
    second = create(:ticket, order: order, ticket_type: type, attendee_name: "Sample attendee two")
    year = create(:registration_question, event: event, kind: :number, scope: :ticket)
    team = create(:registration_question, event: event, kind: :short_text, scope: :order)
    choices = create(:registration_question, event: event, kind: :multi_select, scope: :ticket, options: %w[XL Dinner])
    confirm = create(:registration_question, event: event, kind: :checkbox, scope: :ticket)
    record(year, 1998, ticket: first)
    record(year, 2027, ticket: second)
    record(team, " Class of 1998 ")
    record(choices, %w[XL Dinner], ticket: first)
    record(choices, ["Dinner"], ticket: second)
    record(confirm, false, ticket: first)
    record(confirm, true, ticket: second)

    { year => "1998", choices => "XL", confirm => "false", team => "class OF 1998" }.each do |question, value|
      get "#{base}/attendees", params: { active_only: "true", ticket_type_id: type.id, channel: "box_office",
        question_id: question.id, answer_value: value }, headers: headers
      expect(response).to have_http_status(:ok)
      expect(response.parsed_body["attendees"].pluck("id")).to eq(question == team ? [second.id, first.id] : [first.id])
      row = response.parsed_body["attendees"].find { |item| item["id"] == first.id }
      expect(row).to include("buyer_name" => order.buyer_name, "attendee_name" => first.attendee_name)
      expect(row["registration_answers"].pluck("value")).to contain_exactly(" Class of 1998 ", 1998, %w[XL Dinner], false)
    end
  end

  it "streams filter-matched roster rows with expanded answers, safe headers and formula-safe text" do
    first = create(:ticket, order: order, ticket_type: type, attendee_name: "=2+2")
    second = create(:ticket, order: order, ticket_type: type, attendee_name: "Another attendee")
    question = create(:registration_question, event: event, kind: :selection, scope: :ticket, prompt: "+Size", options: %w[XL L])
    record(question, "XL", ticket: first)
    record(question, "L", ticket: second)
    dangerous = ["=FORMULA()", "+FORMULA()", "-FORMULA()", "@FORMULA()", "\tFORMULA()", "\rFORMULA()"]
    dangerous.each_with_index do |value, index|
      field = create(:registration_question, event: event, kind: :short_text, prompt: "Field #{index}")
      record(field, value)
    end

    get "#{base}/reports/export.csv", params: { report_type: "registrations_roster", ticket_type_id: type.id,
      search: "sample buyer", question_id: question.id, answer_value: "XL", channel: "box_office" }, headers: headers
    expect(response).to have_http_status(:ok)
    expect(response.headers["Content-Disposition"]).to include("#{event.slug}-registrations-roster.csv")
    expect(response.headers["Cache-Control"]).to include("no-store")
    expect(response.body).to start_with("\uFEFF")
    csv = CSV.parse(response.body.delete_prefix("\uFEFF"), headers: true)
    expect(csv.length).to eq(1)
    expect(csv.first["Attendee name"]).to eq("\t=2+2")
    expect(csv.first["\t+Size"]).to eq("XL")
    dangerous.each_with_index { |value, index| expect(csv.first["Field #{index}"]).to eq("\t#{value}") }

    %w[sales_by_tier attendance demographics].each do |report_type|
      get "#{base}/reports/export.csv", params: { report_type: report_type }, headers: headers
      expect(response).to have_http_status(:ok)
      expect(response.headers["Content-Disposition"]).to include("#{event.slug}-#{report_type.tr('_', '-')}.csv")
      expect(response.body).to start_with("\uFEFF")
      expect(response.body).not_to include(SpreadsheetExport::INCOMPLETE_MARKER)
    end
  end

  it "denies cross-organization access, unassigned staff and scan-only members" do
    outsider = create(:organizer_profile)
    get "#{base}/reports", headers: auth_headers(outsider.user).merge("X-Organization-Id" => outsider.organization_id.to_s)
    expect(response).to have_http_status(:not_found)
    get "#{base}/reports", headers: organizer_headers(outsider.user)
    expect(response).to have_http_status(:forbidden)
    [staff(:box_office), staff(:scanner, assigned: true), staff(:marketer)].each do |user|
      get "#{base}/reports", headers: organizer_headers(user)
      expect(response).to have_http_status(:forbidden)
      get "#{base}/reports/export.csv", params: { report_type: "registrations_roster" }, headers: organizer_headers(user)
      expect(response).to have_http_status(:forbidden)
    end
  end

  it "keeps finance and attendee permissions independent for reports, exports and answer access" do
    finance = organizer_headers(staff(:finance))
    box = organizer_headers(staff(:box_office, assigned: true))
    create(:ticket, order: order, ticket_type: type)
    question = create(:registration_question, event: event)
    record(question, "Private registration answer")

    get "#{base}/reports", headers: finance
    expect(response).to have_http_status(:ok)
    expect(response.parsed_body.keys).to contain_exactly("summary", "sales_by_tier", "payout_series")
    get "#{base}/reports", headers: box
    expect(response).to have_http_status(:ok)
    expect(response.parsed_body.keys).to contain_exactly("summary", "attendance", "demographics")
    get "#{base}/reports", params: { report_type: "demographics" }, headers: finance
    expect(response).to have_http_status(:forbidden)
    get "#{base}/reports/export.csv", params: { report_type: "sales_by_tier" }, headers: box
    expect(response).to have_http_status(:forbidden)
    get "#{base}/attendees", headers: finance
    expect(response).to have_http_status(:ok)
    expect(response.parsed_body["attendees"].first.keys).not_to include("registration_answers", "attendee_name", "buyer_name")
    get "#{base}/attendees", params: { question_id: question.id, answer_value: "Private registration answer" }, headers: finance
    expect(response).to have_http_status(:unprocessable_entity)
    expect(response.body).not_to include("Private registration answer")
  end

  it "rejects foreign type and question filters and unrecognized report types" do
    other_event = create(:event, organizer_profile: profile)
    other_type = create(:ticket_type, event: other_event)
    question = create(:registration_question, event: other_event)

    get "#{base}/reports", params: { ticket_type_id: other_type.id }, headers: headers
    expect(response).to have_http_status(:unprocessable_entity)
    get "#{base}/reports/export.csv", params: { report_type: "registrations_roster", question_id: question.id, answer_value: "L" }, headers: headers
    expect(response).to have_http_status(:unprocessable_entity)
    get "#{base}/reports/export.csv", params: { report_type: "other" }, headers: headers
    expect(response).to have_http_status(:unprocessable_entity)
  end
end
