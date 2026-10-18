# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Organizer event-day admissions", type: :request do
  let(:profile) { create(:organizer_profile) }
  let(:organization) { profile.organization }
  let(:owner) { profile.user }
  let(:event) { create(:event, :published, organizer_profile: profile) }
  let(:ticket_type) { create(:ticket_type, event: event) }
  let(:order) { create(:order, event: event, buyer_email: "private@example.com", buyer_name: "Mina Cruz") }
  let!(:ticket) { create(:ticket, event: event, order: order, ticket_type: ticket_type) }
  let(:headers) { auth_headers(owner).merge("X-Organization-Id" => organization.id.to_s) }

  it "authorizes a device, downloads a signed manifest, syncs a scan, and shows live counts" do
    post "/api/v1/organizer/events/#{event.id}/scanner_devices",
      params: { identifier: "browser-a", name: "North door" }, headers: headers

    expect(response).to have_http_status(:created)
    device_id = response.parsed_body.fetch("id")
    expect(response.parsed_body).to include("effective" => true, "last_sequence" => 0)

    get "/api/v1/organizer/events/#{event.id}/scanner_devices/#{device_id}/manifest", headers: headers

    expect(response).to have_http_status(:ok)
    envelope = response.parsed_body
    expect(envelope).to include("algorithm" => "PS256", "digest" => a_string_matching(/\A[0-9a-f]{64}\z/))
    expect(envelope.fetch("public_key_spki")).to be_present
    manifest_ticket = envelope.dig("payload", "tickets", 0)
    expect(manifest_ticket).to include(
      "ticket_id" => ticket.id,
      "attendee_name" => "Mina Cruz",
      "state" => "valid"
    )
    expect(envelope.to_json).not_to include("private@example.com", ticket.scan_credential)

    post "/api/v1/organizer/events/#{event.id}/scanner_devices/#{device_id}/sync", params: {
      actions: [{
        action_uuid: "request-door-scan",
        kind: "admit",
        source: "offline",
        sequence: 1,
        manifest_version: envelope.dig("payload", "version"),
        occurred_at: Time.current.iso8601(6),
        ticket_id: ticket.id,
        credential_hash: manifest_ticket.fetch("credential_hash")
      }]
    }, headers: headers

    expect(response).to have_http_status(:ok)
    expect(response.parsed_body.dig("results", 0)).to include("result" => "accepted", "reason_code" => "admitted")
    expect(response.parsed_body.fetch("summary")).to include("admitted" => 1, "remaining" => 0)
    expect(ticket.reload).to be_checked_in

    get "/api/v1/organizer/events/#{event.id}/admissions", headers: headers
    expect(response).to have_http_status(:ok)
    expect(response.parsed_body.dig("counts", "admitted")).to eq(1)
    expect(response.parsed_body.dig("recent_actions", 0, "attendee")).to include("attendee_name" => "Mina Cruz")
  end

  it "preserves admission history while identifying the exact reversed admission" do
    device = create(:scanner_device, event: event, organization: organization, user: owner)
    manifest = Admissions::ManifestBuilder.call(event: event, actor: owner)
    scan = { action_uuid: "history-first", kind: "admit", source: "online", sequence: 1,
      manifest_version: manifest.version, occurred_at: Time.current.iso8601(6), ticket_id: ticket.id,
      credential_hash: Digest::SHA256.hexdigest(ticket.scan_credential) }
    first = Admissions::Reconciler.call(device: device, actor: owner, actions: [scan]).first.action
    expect(first).to be_result_accepted
    undo = { action_uuid: "history-undo", kind: "reverse", source: "online", sequence: 2,
      manifest_version: manifest.version, occurred_at: Time.current.iso8601(6), reverses_action_uuid: first.action_uuid }
    expect(Admissions::Reconciler.call(device: device, actor: owner, actions: [undo]).first.action).to be_result_accepted
    manifest = Admissions::ManifestBuilder.call(event: event, actor: owner)
    later = Admissions::Reconciler.call(device: device, actor: owner,
      actions: [scan.merge(action_uuid: "history-later", sequence: 3, manifest_version: manifest.version,
        occurred_at: Time.current.iso8601(6))]).first.action
    expect(later).to be_result_accepted
    get "/api/v1/organizer/events/#{event.id}/admissions", headers: headers
    expect(response).to have_http_status(:ok)
    history = response.parsed_body.fetch("recent_actions").index_by { |action| action.fetch("action_uuid") }
    expect(history.fetch(first.action_uuid)).to include("reversed" => true, "result" => "accepted")
    expect(history.fetch(later.action_uuid)).to include("reversed" => false, "result" => "accepted")
    expect(response.parsed_body.dig("permissions", "can_reverse")).to be(true)
  end

  it "limits scanner devices to assigned events and minimum attendee information" do
    scanner = create(:user)
    create(:organization_membership, organization: organization, user: scanner, role: :scanner)
    assignment = create(:event_staff_assignment, organization: organization, event: event, user: scanner, role: :scanner)
    scanner_headers = auth_headers(scanner).merge("X-Organization-Id" => organization.id.to_s)

    post "/api/v1/organizer/events/#{event.id}/scanner_devices",
      params: { identifier: "scanner-browser", name: "South door" }, headers: scanner_headers
    expect(response).to have_http_status(:created)
    device_id = response.parsed_body.fetch("id")

    get "/api/v1/organizer/events/#{event.id}/admissions/search", params: { q: "Mina" }, headers: scanner_headers
    expect(response).to have_http_status(:ok)
    expect(response.parsed_body.first).to include("attendee_name" => "Mina Cruz", "code" => "HP-T#{ticket.id}")
    expect(response.body).not_to include("private@example.com")

    other_event = create(:event, :published, organizer_profile: profile)
    post "/api/v1/organizer/events/#{other_event.id}/scanner_devices",
      params: { identifier: "other-browser", name: "Wrong event" }, headers: scanner_headers
    expect(response).to have_http_status(:unprocessable_entity)
    expect(response.parsed_body.fetch("error")).to include("not assigned")

    assignment.update!(status: :revoked)
    get "/api/v1/organizer/events/#{event.id}/scanner_devices/#{device_id}/manifest", headers: scanner_headers
    expect(response).to have_http_status(:forbidden)
  end

  it "produces a printable emergency list for authorized door managers" do
    get "/api/v1/organizer/events/#{event.id}/admissions/door_list", headers: headers

    expect(response).to have_http_status(:ok)
    expect(response.media_type).to eq("application/pdf")
    expect(response.body).to start_with("%PDF")
  end
end
