# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Scanner door verification", type: :request do
  let(:profile) { create(:organizer_profile) }
  let(:event) { create(:event, :published, organizer_profile: profile) }
  let(:owner) { profile.user }
  let(:headers) { auth_headers(owner).merge("X-Organization-Id" => event.organization_id.to_s) }
  let(:device) { create(:scanner_device, organization: event.organization, event: event, user: owner) }
  let(:base) { "/api/v1/organizer/events/#{event.id}/scanner_devices/#{device.id}" }
  let(:type) { create(:ticket_type, event: event, name: "Alumni") }
  let(:order) { create(:order, event: event, buyer_name: "Pat Cruz") }
  let!(:ticket) { create(:ticket, event: event, order: order, ticket_type: type, attendee_name: "Maria Cruz") }

  def prepare
    get "#{base}/manifest", headers: headers
    expect(response).to have_http_status(:ok)
    payload = response.parsed_body.fetch("payload")
    @scan = { ticket_id: ticket.id, manifest_version: payload.fetch("version"),
      credential_hash: payload.fetch("tickets").sole.fetch("credential_hash") }
  end

  def scan(**changes)
    post "#{base}/scan", params: @scan.merge(changes), headers: headers, as: :json
    expect(response).to have_http_status(:ok)
    response.parsed_body
  end

  def sync(sequence: 1, source: "online", **changes)
    action = @scan.merge(action_uuid: "door-#{sequence}", kind: "admit", source: source, sequence: sequence,
      occurred_at: Time.current.iso8601(6)).merge(changes)
    post "#{base}/sync", params: { actions: [action] }, headers: headers, as: :json
    expect(response).to have_http_status(:ok)
    response.parsed_body.fetch("results").sole
  end

  it "admits instant tickets in the normal scan flow and returns the door payload" do
    prepare
    expect(scan).to include("status" => "ready", "verification_required" => false)
    result = sync
    expect(result).to include("result" => "accepted", "reason_code" => "admitted")
    expect(result.fetch("ticket")).to include("attendee_name" => "Maria Cruz", "ticket_type_name" => "Alumni",
      "door_check_mode" => "instant", "door_fields" => [], "door_alert_label" => nil, "door_instructions" => nil)
    expect(result.fetch("ticket")).not_to have_key("buyer_name")
    expect(ticket.reload).to be_checked_in
  end

  it "holds without persisting, allows cancellation, and admits only on explicit confirmation" do
    type.update!(door_check_mode: "verify", door_alert_label: "CHECK ID", door_instructions: "Confirm graduation year",
      scanner_show_buyer: true)
    question = create(:registration_question, event: event, kind: :number, scope: :ticket, prompt: "Graduation Year", show_on_scanner: true)
    order.registration_responses.create!(ticket: ticket, registration_question: question, prompt_snapshot: question.prompt,
      kind_snapshot: RegistrationQuestion.kinds.fetch("number"), answered_at: Time.current, answer: { "value" => 1998 })
    prepare

    hold = scan
    expect(hold).to include("status" => "verification_required", "verification_required" => true)
    expect(hold.fetch("ticket")).to include("ticket_id" => ticket.id, "attendee_name" => "Maria Cruz",
      "buyer_name" => "Pat Cruz", "ticket_type_name" => "Alumni", "door_check_mode" => "verify",
      "door_alert_label" => "CHECK ID", "door_instructions" => "Confirm graduation year",
      "door_fields" => [{ "label" => "Graduation Year", "value" => "1998" }])
    # Canceling the hold sends no action. A second scan can still hold it.
    expect(scan).to eq(hold)
    expect(ticket.reload).to be_issued
    expect(ticket.admission_actions).to be_empty
    expect(device.reload.last_sequence).to eq(0)

    result = sync(confirmed: true)
    expect(result.fetch("ticket")).to include(hold.fetch("ticket").slice("buyer_name", "door_fields", "door_alert_label"))
    expect(result).to include("result" => "accepted")
    expect(sync(confirmed: true)).to eq(result)
    expect(ticket.reload).to be_checked_in
    expect(scan).to include("status" => "rejected", "reason_code" => "already_admitted")
    expect(sync(sequence: 2, confirmed: true)).to include("result" => "conflict", "reason_code" => "already_admitted")
  end

  it "rejects invalid, wrong-event, refund-pending and cancelled tickets ahead of verification" do
    type.update!(door_check_mode: "verify")
    prepare
    expect(scan(credential_hash: "a" * 64)).to include("status" => "rejected", "reason_code" => "credential_not_in_manifest")
    other = create(:ticket)
    expect(scan(ticket_id: other.id, credential_hash: Digest::SHA256.hexdigest(other.scan_credential)))
      .to include("status" => "rejected", "reason_code" => "credential_not_in_manifest")
    refund = create(:refund, order: order, status: :pending, provider_refund_id: nil, succeeded_at: nil)
    refund.refund_tickets.create!(ticket: ticket, amount_cents: refund.amount_cents)
    expect(scan).to include("status" => "rejected", "reason_code" => "refund_pending")
    ticket.update!(status: :cancelled)
    expect(scan).to include("status" => "rejected", "reason_code" => "cancelled")
    expect(ticket.reload).not_to be_checked_in
    expect(ticket.admission_actions).to be_empty
  end

  it "syncs a verified offline admission and rejects unconfirmed v2 actions" do
    type.update!(door_check_mode: "verify")
    prepare
    expect(sync(source: "offline", confirmed: "true")).to include("result" => "rejected", "reason_code" => "verification_required")
    expect(ticket.reload).to be_issued
    expect(sync(sequence: 2, source: "offline", confirmed: true)).to include("result" => "accepted")
    expect(ticket.reload).to be_checked_in
    expect(ticket.admission_actions.result_accepted.sole.metadata).to include("confirmed" => true)
  end

  it "enforces a new live hold against a previously downloaded instant list" do
    prepare
    type.update!(door_check_mode: "verify")
    expect(scan).to include("status" => "verification_required", "verification_required" => true)
    expect(sync).to include("result" => "rejected", "reason_code" => "verification_required")
    expect(ticket.reload).to be_issued
    expect(sync(sequence: 2, confirmed: true)).to include("result" => "accepted")
  end
end
