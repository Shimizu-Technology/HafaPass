# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Box office receipts", type: :request do
  let(:profile) { create(:organizer_profile) }
  let(:organization) { profile.organization }
  let(:event) { create(:event, :published, organizer_profile: profile, starts_at: 3.days.from_now) }
  let(:staff) { create(:user) }
  let(:assignment) { create(:event_staff_assignment, event: event, user: staff, role: :box_office) }
  let(:headers) { auth_headers(staff).merge("X-Organization-Id" => organization.id.to_s) }
  let(:sale_path) { "/api/v1/organizer/events/#{event.id}/box_office" }
  let(:ticket_type) { create(:ticket_type, event: event, quantity_available: 50, max_per_order: nil) }

  before do
    create(:organization_membership, organization: organization, user: staff, role: :box_office)
    assignment
  end

  def record_sale(ticket_type:, quantity: 1, **buyer)
    post sale_path, params: { line_items: [{ ticket_type_id: ticket_type.id, quantity: quantity }],
                             payment_method: "door_cash", **buyer }, headers: headers
    expect(response).to have_http_status(:created)
    Order.find(response.parsed_body.fetch("id"))
  end

  it "reloads 20 admissions with original scan credentials and handles missing buyer details" do
    order = record_sale(ticket_type: ticket_type, quantity: 20)
    initial_receipt = response.parsed_body.fetch("receipt")
    get "#{sale_path}/orders/#{order.id}", headers: headers
    expect(response).to have_http_status(:ok)
    expect(response.parsed_body).to eq(initial_receipt)
    expect(response.headers["Cache-Control"]).to include("no-store")
    expect(response.parsed_body).to include("reference" => order.reference, "event_title" => event.title, "email" => nil)
    admissions = response.parsed_body.fetch("admissions")
    expect(admissions.size).to eq(20)
    expect(admissions.pluck("scan_credential")).to eq(order.tickets.order(:id).map(&:scan_credential))
    expect(admissions).to all(include("attendee_name" => nil, "tier" => ticket_type.name,
      "event" => a_hash_including("venue_name" => event.venue_name, "timezone" => event.timezone)))
  end

  it "prints one child per night and keeps the pass title, venue, tier and attendee text" do
    ticket_type.update!(is_pass: true)
    nights = Array.new(3) do |index|
      create(:event, :published, organizer_profile: profile, title: "Fictional Night #{index + 1}",
        starts_at: (index + 4).days.from_now)
    end
    nights.each { |night| ticket_type.ticket_type_included_events.create!(included_event: night) }
    name = "練習用選手🌺#{"W" * 100}"
    order = record_sale(ticket_type: ticket_type, buyer_name: name)
    get "#{sale_path}/orders/#{order.id}", headers: headers
    expect(response).to have_http_status(:ok)
    expect(response.parsed_body.fetch("event_title")).to eq(event.title)
    admissions = response.parsed_body.fetch("admissions")
    expect(admissions.size).to eq(3)
    expect(admissions).to all(include("attendee_name" => name, "tier" => ticket_type.name, "pass_night" => true))
    expect(admissions.map { |admission| admission.dig("event", "title") }).to match_array(nights.map(&:title))
    expect(admissions.pluck("scan_credential")).to match_array(order.tickets.where.not(parent_ticket_id: nil).map(&:scan_credential))
  end

  it "rejects an order outside the event and revokes reload and email access with the assignment" do
    order = record_sale(ticket_type: ticket_type)
    another_event = create(:event, :published, organizer_profile: profile)
    foreign_order = create(:order, :completed, event: another_event, source: "box_office", sold_by: staff)
    get "#{sale_path}/orders/#{foreign_order.id}", headers: headers
    expect(response).to have_http_status(:not_found)
    assignment.destroy!
    get "#{sale_path}/orders/#{order.id}", headers: headers
    expect(response).to have_http_status(:forbidden)
    post "#{sale_path}/orders/#{order.id}/email", params: { email: "buyer@example.test" }, headers: headers
    expect(response).to have_http_status(:forbidden)
  end

  it "excludes another seller's receipt and non-box-office orders" do
    [
      create(:order, :completed, event: event, source: "box_office", sold_by: profile.user),
      create(:order, :completed, event: event, sold_by: staff)
    ].each do |order|
      get "#{sale_path}/orders/#{order.id}", headers: headers
      expect(response).to have_http_status(:not_found)
    end
  end

  it "never includes cancelled or transferred admission credentials" do
    order = record_sale(ticket_type: ticket_type, quantity: 3)
    cancelled, transferred, active = order.tickets.order(:id)
    cancelled.update!(status: :cancelled)
    transferred.update!(holder_user: create(:user))
    get "#{sale_path}/orders/#{order.id}", headers: headers
    expect(response.parsed_body.fetch("admissions").pluck("id")).to eq([active.id])
  end

  it "adds a walk-in email, preserves recovery ownership, and queues fulfillment only once on retry" do
    order = record_sale(ticket_type: ticket_type)
    params = { email: "Player@example.test" }
    expect(Resend::Emails).not_to receive(:send)
    expect do
      post "#{sale_path}/orders/#{order.id}/email", params: params, headers: headers
    end.to change { order.message_deliveries.where(template: "fulfillment_resend").count }.by(1)
    expect(response).to have_http_status(:accepted)
    expect(response.parsed_body).to eq("email" => "player@example.test", "email_status" => "queued")
    expect(order.reload.buyer_email).to eq("player@example.test")
    expect(order.tickets.sole.holder_email).to eq("player@example.test")

    expect do
      post "#{sale_path}/orders/#{order.id}/email", params: params, headers: headers
    end.not_to change { order.message_deliveries.count }
    expect(response).to have_http_status(:accepted)
    post "#{sale_path}/orders/#{order.id}/email", params: { email: "other@example.test" }, headers: headers
    expect(response).to have_http_status(:unprocessable_entity)
    expect(order.reload.buyer_email).to eq("player@example.test")
  end

  it "confirms an already queued purchase email without sending a duplicate" do
    order = record_sale(ticket_type: ticket_type, buyer_email: "player@example.test")
    expect do
      post "#{sale_path}/orders/#{order.id}/email", params: { email: order.buyer_email }, headers: headers
    end.not_to change { order.message_deliveries.count }
    expect(response).to have_http_status(:accepted)
    expect(response.parsed_body.fetch("email_status")).to eq("queued")
  end
end
