# frozen_string_literal: true

require "rails_helper"
require "csv"

RSpec.describe "Event re-entry, live headcount, lead override, and reports", type: :request do
  include ActiveSupport::Testing::TimeHelpers

  let(:profile) { create(:organizer_profile) }
  let(:organization) { profile.organization }
  let(:owner) { profile.user }
  let(:headers) { auth_headers(owner).merge("X-Organization-Id" => organization.id.to_s) }
  let(:event) do
    create(:event, :published,
      organizer_profile: profile,
      timezone: "Pacific/Guam",
      starts_at: Time.zone.parse("2027-01-30T08:00:00+10:00"),
      ends_at: Time.zone.parse("2027-01-31T22:00:00+10:00"))
  end
  let(:ticket_type) { create(:ticket_type, event: event, name: "Spectator Adult") }
  let(:order) { create(:order, event: event, buyer_name: "Avery Lindqvist", buyer_email: "avery@example.com") }
  let!(:ticket) { create(:ticket, event: event, order: order, ticket_type: ticket_type, attendee_name: "Avery Lindqvist") }

  after { travel_back }

  def register_device(user:, identifier:, name:)
    user_headers = auth_headers(user).merge("X-Organization-Id" => organization.id.to_s)
    post "/api/v1/organizer/events/#{event.id}/scanner_devices",
      params: { identifier: identifier, name: name }, headers: user_headers, as: :json
    expect(response).to have_http_status(:created)
    ScannerDevice.find(response.parsed_body.fetch("id"))
  end

  def fetch_manifest(device, user: owner)
    user_headers = auth_headers(user).merge("X-Organization-Id" => organization.id.to_s)
    get "/api/v1/organizer/events/#{event.id}/scanner_devices/#{device.id}/manifest", headers: user_headers
    expect(response).to have_http_status(:ok)
    response.parsed_body
  end

  def sync_actions(device, actions, user: owner)
    user_headers = auth_headers(user).merge("X-Organization-Id" => organization.id.to_s)
    post "/api/v1/organizer/events/#{event.id}/scanner_devices/#{device.id}/sync",
      params: { actions: actions }, headers: user_headers, as: :json
    expect(response).to have_http_status(:ok)
    response.parsed_body
  end

  def preview_scan(device, ticket:, manifest:, kind: "admit", user: owner)
    user_headers = auth_headers(user).merge("X-Organization-Id" => organization.id.to_s)
    post "/api/v1/organizer/events/#{event.id}/scanner_devices/#{device.id}/scan", params: {
      ticket_id: ticket.id,
      credential_hash: Digest::SHA256.hexdigest(ticket.scan_credential),
      manifest_version: manifest.dig("payload", "version"),
      kind: kind
    }, headers: user_headers, as: :json
    expect(response).to have_http_status(:ok)
    response.parsed_body
  end

  def scan_payload(ticket:, manifest:, sequence:, kind: "admit", source: "online", occurred_at: Time.current, action_uuid: SecureRandom.uuid)
    {
      action_uuid: action_uuid,
      kind: kind,
      source: source,
      sequence: sequence,
      manifest_version: manifest.dig("payload", "version"),
      occurred_at: occurred_at.iso8601(6),
      ticket_id: ticket.id,
      credential_hash: Digest::SHA256.hexdigest(ticket.scan_credential)
    }
  end

  describe "per-event re-entry settings" do
    it "defaults to off and saves exit_scan and cooldown configurations in Guam time" do
      expect(event.re_entry_mode).to eq("off")

      put "/api/v1/organizer/events/#{event.id}", params: {
        re_entry_mode: "exit_scan",
        re_entry_max_count: 3,
        re_entry_cutoff_time: "21:00"
      }, headers: headers, as: :json
      expect(response).to have_http_status(:ok)
      expect(response.parsed_body).to include(
        "re_entry_mode" => "exit_scan",
        "re_entry_max_count" => 3,
        "re_entry_cutoff_time" => "21:00"
      )
      expect(event.reload.re_entry_cutoff_time).to eq("21:00")

      put "/api/v1/organizer/events/#{event.id}", params: {
        re_entry_cutoff_time: "25:99"
      }, headers: headers, as: :json
      expect(response).to have_http_status(:unprocessable_entity)

      put "/api/v1/organizer/events/#{event.id}", params: {
        re_entry_mode: "cooldown",
        re_entry_cooldown_minutes: nil
      }, headers: headers, as: :json
      expect(response).to have_http_status(:unprocessable_entity)
      expect(response.parsed_body.fetch("errors").join).to include("Cool-down")

      put "/api/v1/organizer/events/#{event.id}", params: {
        re_entry_mode: "cooldown",
        re_entry_cooldown_minutes: 15
      }, headers: headers, as: :json
      expect(response).to have_http_status(:ok)
      expect(response.parsed_body).to include("re_entry_mode" => "cooldown", "re_entry_cooldown_minutes" => 15)
    end
  end

  describe "mode off regression" do
    it "keeps standard single-entry behavior, skips re-entry headcount replay, and refuses exits and overrides" do
      travel_to(Time.zone.parse("2027-01-30T10:00:00+10:00"))
      device = register_device(user: owner, identifier: "gate-off", name: "Gate 1")
      manifest = fetch_manifest(device)
      # Minor #2: Off-mode manifest stays identical to main (no re-entry event/ticket fields)
      expect(manifest.dig("payload", "event").keys).to match_array(%w[id title status venue_name starts_at ends_at timezone])
      manifest_ticket = manifest.dig("payload", "tickets", 0)
      %w[occupancy_state occupancy_day last_entry_at last_entry_gate last_exit_at re_entry_count re_entry_conflict_flagged].each do |key|
        expect(manifest_ticket).not_to have_key(key)
      end

      expect(Admissions::ReEntryReport).not_to receive(:call)

      first = sync_actions(device, [scan_payload(ticket: ticket, manifest: manifest, sequence: 1)])
      expect(first.dig("results", 0)).to include("result" => "accepted", "reason_code" => "admitted")
      # Minor #1 & R3: Off-mode sync summary and results[].ticket stay identical to main
      expect(first.fetch("summary").keys).to match_array(%w[total issued admitted cancelled eligible_unadmitted conflicts rejected remaining])
      %w[occupancy_state occupancy_day re_entry_count].each do |key|
        expect(first.dig("results", 0, "ticket")).not_to have_key(key)
      end

      duplicate = sync_actions(device, [scan_payload(ticket: ticket, manifest: manifest, sequence: 2)])
      expect(duplicate.dig("results", 0)).to include("result" => "conflict", "reason_code" => "already_admitted")

      exit_preview = preview_scan(device, ticket: ticket, manifest: manifest, kind: "exit")
      expect(exit_preview).to include("status" => "rejected", "reason_code" => "re_entry_disabled")

      exit_sync = sync_actions(device, [scan_payload(ticket: ticket, manifest: manifest, sequence: 3, kind: "exit")])
      expect(exit_sync.dig("results", 0)).to include("result" => "rejected", "reason_code" => "re_entry_disabled")

      # Lead override is refused when re-entry mode is off
      get "/api/v1/organizer/events/#{event.id}/admissions", headers: headers
      expect(response.parsed_body.dig("permissions", "can_override")).to be(false)

      post "/api/v1/organizer/events/#{event.id}/admissions/override", params: {
        ticket_id: ticket.id, override_action: "admit", reason: "Should be refused while off"
      }, headers: headers, as: :json
      expect(response).to have_http_status(:unprocessable_entity)
      expect(response.parsed_body.fetch("error")).to include("off")
    end
  end

  describe "exit_scan mode: anti-passback, exits, re-entry cap, cutoff, and headcount" do
    before do
      event.update!(
        re_entry_mode: "exit_scan",
        re_entry_max_count: 1,
        re_entry_cutoff_time: "18:00"
      )
    end

    it "enforces anti-passback, exit-before-re-entry, cap, cutoff, and live headcount" do
      travel_to(Time.zone.parse("2027-01-30T10:00:00+10:00"))
      gate1 = register_device(user: owner, identifier: "gate-1", name: "Gate 1")
      manifest = fetch_manifest(gate1)
      expect(manifest.dig("payload", "event")).to include("re_entry_mode" => "exit_scan", "re_entry_max_count" => 1)
      expect(manifest.dig("payload", "tickets", 0)).to include("occupancy_state" => "outside", "re_entry_count" => 0)

      # Exit when not inside is flagged cleanly
      not_inside = sync_actions(gate1, [scan_payload(ticket: ticket, manifest: manifest, sequence: 1, kind: "exit")])
      expect(not_inside.dig("results", 0)).to include("result" => "conflict", "reason_code" => "not_inside")
      expect(not_inside.dig("summary", "live_headcount")).to eq(0)

      # First entry succeeds
      entry1 = sync_actions(gate1, [scan_payload(ticket: ticket, manifest: manifest, sequence: 2, kind: "admit")])
      expect(entry1.dig("results", 0)).to include("result" => "accepted", "reason_code" => "admitted")
      expect(entry1.dig("summary", "live_headcount")).to eq(1)
      expect(ticket.reload).to have_attributes(occupancy_state: "inside", re_entry_count: 0, last_entry_device_id: gate1.id)

      # Anti-passback: scanning Entry while already inside returns already_inside with gate and time
      preview = preview_scan(gate1, ticket: ticket, manifest: manifest, kind: "admit")
      expect(preview).to include("status" => "rejected", "reason_code" => "already_inside")
      expect(preview.fetch("details")).to include("prior_gate_name" => "Gate 1", "prior_entry_at" => be_present)

      anti_passback = sync_actions(gate1, [scan_payload(ticket: ticket, manifest: manifest, sequence: 3, kind: "admit")])
      expect(anti_passback.dig("results", 0)).to include("result" => "conflict", "reason_code" => "already_inside")
      expect(anti_passback.dig("results", 0, "details")).to include("prior_gate_name" => "Gate 1")

      # Updated manifest carries inside state + gate name
      manifest2 = fetch_manifest(gate1)
      expect(manifest2.dig("payload", "tickets", 0)).to include("occupancy_state" => "inside", "last_entry_gate" => "Gate 1")

      # Exit scan records exit and drops headcount to 0
      travel_to(Time.zone.parse("2027-01-30T11:00:00+10:00"))
      exit1 = sync_actions(gate1, [scan_payload(ticket: ticket, manifest: manifest2, sequence: 4, kind: "exit")])
      expect(exit1.dig("results", 0)).to include("result" => "accepted", "reason_code" => "exited")
      expect(exit1.dig("summary")).to include("live_headcount" => 0, "exits" => 1)
      expect(ticket.reload.occupancy_state).to eq("outside")

      # First re-entry allowed (within cap = 1, before cutoff)
      travel_to(Time.zone.parse("2027-01-30T12:00:00+10:00"))
      reenter1 = sync_actions(gate1, [scan_payload(ticket: ticket, manifest: manifest2, sequence: 5, kind: "admit")])
      expect(reenter1.dig("results", 0)).to include("result" => "accepted", "reason_code" => "re_entered")
      expect(reenter1.dig("summary")).to include("live_headcount" => 1, "re_entries" => 1)
      expect(ticket.reload.re_entry_count).to eq(1)

      # Exit again, then try 2nd re-entry -> blocked by cap (max = 1)
      travel_to(Time.zone.parse("2027-01-30T13:00:00+10:00"))
      sync_actions(gate1, [scan_payload(ticket: ticket, manifest: manifest2, sequence: 6, kind: "exit")])
      cap_hit = sync_actions(gate1, [scan_payload(ticket: ticket, manifest: manifest2, sequence: 7, kind: "admit")])
      expect(cap_hit.dig("results", 0)).to include("result" => "rejected", "reason_code" => "re_entry_limit_reached")
      expect(cap_hit.dig("results", 0, "details")).to include("re_entry_count" => 1, "re_entry_max_count" => 1)

      # Cutoff test: increase cap, jump past 6:00 PM cutoff -> re-entry blocked, but a fresh ticket's first entry succeeds!
      event.update!(re_entry_max_count: 5)
      fresh_ticket = create(:ticket, event: event, order: order, ticket_type: ticket_type, attendee_name: "Bram Okafor")
      travel_to(Time.zone.parse("2027-01-30T18:30:00+10:00"))
      manifest3 = fetch_manifest(gate1)

      cutoff_hit = sync_actions(gate1, [scan_payload(ticket: ticket, manifest: manifest3, sequence: 8, kind: "admit")])
      expect(cutoff_hit.dig("results", 0)).to include("result" => "rejected", "reason_code" => "re_entry_cutoff_passed")

      first_entry_late = sync_actions(gate1, [scan_payload(ticket: fresh_ticket, manifest: manifest3, sequence: 9, kind: "admit")])
      expect(first_entry_late.dig("results", 0)).to include("result" => "accepted", "reason_code" => "admitted")
    end
  end

  describe "cooldown mode" do
    before do
      event.update!(
        re_entry_mode: "cooldown",
        re_entry_cooldown_minutes: 15,
        re_entry_max_count: 1,
        re_entry_cutoff_time: "20:00"
      )
    end

    it "blocks rescans inside cooldown window, allows after cooldown, and enforces cap and cutoff" do
      travel_to(Time.zone.parse("2027-01-30T14:00:00+10:00"))
      gate = register_device(user: owner, identifier: "cool-gate", name: "Main Entrance")
      manifest = fetch_manifest(gate)

      # Initial entry
      first = sync_actions(gate, [scan_payload(ticket: ticket, manifest: manifest, sequence: 1)])
      expect(first.dig("results", 0)).to include("result" => "accepted", "reason_code" => "admitted")

      # Exit scan is not used in cooldown mode
      exit_try = sync_actions(gate, [scan_payload(ticket: ticket, manifest: manifest, sequence: 2, kind: "exit")])
      expect(exit_try.dig("results", 0)).to include("result" => "rejected", "reason_code" => "re_entry_exit_not_used")

      # 2 minutes later -> blocked by cooldown
      travel_to(Time.zone.parse("2027-01-30T14:02:00+10:00"))
      too_soon = sync_actions(gate, [scan_payload(ticket: ticket, manifest: manifest, sequence: 3)])
      expect(too_soon.dig("results", 0)).to include("result" => "conflict", "reason_code" => "cooldown_active")
      expect(too_soon.dig("results", 0, "details")).to include("elapsed_minutes" => 2, "cooldown_minutes" => 15, "prior_gate_name" => "Main Entrance")

      # 16 minutes later -> allowed as re-entry!
      travel_to(Time.zone.parse("2027-01-30T14:16:00+10:00"))
      reenter = sync_actions(gate, [scan_payload(ticket: ticket, manifest: manifest, sequence: 4)])
      expect(reenter.dig("results", 0)).to include("result" => "accepted", "reason_code" => "re_entered")
      expect(ticket.reload.re_entry_count).to eq(1)

      # Another 20 minutes later -> blocked by cap (max = 1)
      travel_to(Time.zone.parse("2027-01-30T14:36:00+10:00"))
      cap_hit = sync_actions(gate, [scan_payload(ticket: ticket, manifest: manifest, sequence: 5)])
      expect(cap_hit.dig("results", 0)).to include("result" => "rejected", "reason_code" => "re_entry_limit_reached")
    end
  end

  describe "offline conflict resolution, idempotency, and lead override" do
    let(:scanner_user) { create(:user) }
    let(:lead_user) { create(:user) }

    before do
      event.update!(re_entry_mode: "exit_scan")
      create(:organization_membership, organization: organization, user: scanner_user, role: :scanner)
      create(:event_staff_assignment, organization: organization, event: event, user: scanner_user, role: :scanner)
      create(:organization_membership, organization: organization, user: lead_user, role: :scanner)
      create(:event_staff_assignment, organization: organization, event: event, user: lead_user, role: :scanner_lead)
    end

    it "resolves offline conflicts by occurred_at, keeps retries idempotent, and audits scanner_lead overrides" do
      travel_to(Time.zone.parse("2027-01-30T18:40:00+10:00"))
      gate1 = register_device(user: scanner_user, identifier: "offline-g1", name: "Gate 1")
      gate2 = register_device(user: lead_user, identifier: "offline-g2", name: "Gate 2")
      manifest = fetch_manifest(gate1, user: scanner_user)

      # Gate 1 scans at 18:42 offline; Gate 2 scans SAME ticket at 18:43 offline.
      # Gate 2 reconnects FIRST at 18:45; Gate 1 reconnects SECOND at 18:46.
      travel_to(Time.zone.parse("2027-01-30T18:45:00+10:00"))
      g2_action = scan_payload(ticket: ticket, manifest: manifest, sequence: 1, source: "offline",
        occurred_at: Time.zone.parse("2027-01-30T18:43:00+10:00"), action_uuid: "offline-g2-uuid")
      g2_sync = sync_actions(gate2, [g2_action], user: lead_user)
      expect(g2_sync.dig("results", 0)).to include("result" => "accepted", "reason_code" => "admitted")

      # Idempotent retry of the exact same action_uuid never double-counts
      g2_retry = sync_actions(gate2, [g2_action], user: lead_user)
      expect(g2_retry.dig("results", 0)).to include("result" => "accepted", "action_uuid" => "offline-g2-uuid")
      expect(AdmissionAction.where(action_uuid: "offline-g2-uuid").count).to eq(1)

      # Now Gate 1 syncs its earlier 18:42 scan -> conflict flagged AND earlier occurred_at wins!
      travel_to(Time.zone.parse("2027-01-30T18:46:00+10:00"))
      g1_action = scan_payload(ticket: ticket, manifest: manifest, sequence: 1, source: "offline",
        occurred_at: Time.zone.parse("2027-01-30T18:42:00+10:00"), action_uuid: "offline-g1-uuid")
      g1_sync = sync_actions(gate1, [g1_action], user: scanner_user)
      expect(g1_sync.dig("results", 0)).to include("result" => "conflict", "reason_code" => "already_inside")
      expect(g1_sync.dig("results", 0, "details")).to include("offline_conflict" => true, "winner_by_occurred_at" => true)
      expect(ticket.reload).to have_attributes(
        re_entry_conflict_flagged: true,
        last_entry_device_id: gate1.id,
        last_entry_at: Time.zone.parse("2027-01-30T18:42:00+10:00")
      )

      # Dashboard shows flagged conflict and permissions
      scanner_headers = auth_headers(scanner_user).merge("X-Organization-Id" => organization.id.to_s)
      lead_headers = auth_headers(lead_user).merge("X-Organization-Id" => organization.id.to_s)

      get "/api/v1/organizer/events/#{event.id}/admissions", headers: scanner_headers
      expect(response.parsed_body.dig("permissions", "can_override")).to be(false)
      expect(response.parsed_body.fetch("flagged_conflicts").map { |t| t["id"] }).to eq([ticket.id])

      get "/api/v1/organizer/events/#{event.id}/admissions", headers: lead_headers
      expect(response.parsed_body.dig("permissions", "can_override")).to be(true)

      # Regular scanner cannot override (403)
      post "/api/v1/organizer/events/#{event.id}/admissions/override", params: {
        ticket_id: ticket.id, override_action: "clear", reason: "Trying without lead role"
      }, headers: scanner_headers, as: :json
      expect(response).to have_http_status(:forbidden)

      # Scanner lead requires a reason
      post "/api/v1/organizer/events/#{event.id}/admissions/override", params: {
        ticket_id: ticket.id, override_action: "clear", reason: ""
      }, headers: lead_headers, as: :json
      expect(response).to have_http_status(:unprocessable_entity)

      # Scanner lead clears the stuck conflict with a reason -> audited & idempotent!
      override_uuid = "lead-clear-1"
      post "/api/v1/organizer/events/#{event.id}/admissions/override", params: {
        ticket_id: ticket.id, override_action: "clear", reason: "Verified wristband at North Gate; clearing duplicate offline scan",
        action_uuid: override_uuid, scanner_device_id: gate2.id
      }, headers: lead_headers, as: :json
      expect(response).to have_http_status(:ok)
      expect(response.parsed_body.dig("action")).to include("kind" => "override", "reason_code" => "lead_override_cleared")
      expect(response.parsed_body.dig("summary", "live_headcount")).to eq(0)
      expect(ticket.reload).to have_attributes(occupancy_state: "outside", re_entry_conflict_flagged: false)

      audit = AuditLog.where(action: "ticket.re_entry_overridden").last!
      expect(audit.actor_user_id).to eq(lead_user.id)
      expect(audit.metadata).to include(
        "override_action" => "clear",
        "override_justification" => "Verified wristband at North Gate; clearing duplicate offline scan",
        "reason" => "Verified wristband at North Gate; clearing duplicate offline scan"
      )
      projected = AuditActions.organization_payload("ticket.re_entry_overridden", metadata: audit.metadata)
      expect(projected[:metadata]).to include(
        "override_action" => "clear",
        "override_justification" => "Verified wristband at North Gate; clearing duplicate offline scan"
      )

      # Override refuses a scanner_device_id owned by another staff member
      post "/api/v1/organizer/events/#{event.id}/admissions/override", params: {
        ticket_id: ticket.id, override_action: "admit", reason: "Using another user's device",
        scanner_device_id: gate1.id
      }, headers: lead_headers, as: :json
      expect(response).to have_http_status(:unprocessable_entity)
      expect(response.parsed_body.fetch("error")).to include("Scanner device")

      # Replay same action_uuid -> idempotent, no duplicate action
      post "/api/v1/organizer/events/#{event.id}/admissions/override", params: {
        ticket_id: ticket.id, override_action: "clear", reason: "Verified wristband at North Gate; clearing duplicate offline scan",
        action_uuid: override_uuid, scanner_device_id: gate2.id
      }, headers: lead_headers, as: :json
      expect(response).to have_http_status(:ok)
      expect(AdmissionAction.where(action_uuid: override_uuid).count).to eq(1)

      # Cancelled ticket cannot be overridden
      cancelled = create(:ticket, :cancelled, event: event, order: order, ticket_type: ticket_type)
      post "/api/v1/organizer/events/#{event.id}/admissions/override", params: {
        ticket_id: cancelled.id, override_action: "admit", reason: "Should fail because cancelled"
      }, headers: lead_headers, as: :json
      expect(response).to have_http_status(:unprocessable_entity)
    end
  end

  describe "multi-day state, per-day headcount, and reports + CSV" do
    before { event.update!(re_entry_mode: "exit_scan") }

    it "isolates per-day state on multi-day events and computes accurate report and CSV numbers" do
      ticket2 = create(:ticket, event: event, order: order, ticket_type: ticket_type, attendee_name: "Calla Yorke")
      travel_to(Time.zone.parse("2027-01-30T09:00:00+10:00"))
      gate = register_device(user: owner, identifier: "multi-day-gate", name: "Main Gate")
      manifest = fetch_manifest(gate)

      # Day 1: Ticket 1 enters at 09:00, Ticket 2 enters at 09:15 (peak = 2 at 09:15), Ticket 2 exits at 10:00, re-enters at 11:00
      sync_actions(gate, [scan_payload(ticket: ticket, manifest: manifest, sequence: 1, occurred_at: Time.zone.parse("2027-01-30T09:00:00+10:00"))])
      travel_to(Time.zone.parse("2027-01-30T09:15:00+10:00"))
      sync_actions(gate, [scan_payload(ticket: ticket2, manifest: manifest, sequence: 2, occurred_at: Time.zone.parse("2027-01-30T09:15:00+10:00"))])
      travel_to(Time.zone.parse("2027-01-30T10:00:00+10:00"))
      sync_actions(gate, [scan_payload(ticket: ticket2, manifest: manifest, sequence: 3, kind: "exit", occurred_at: Time.zone.parse("2027-01-30T10:00:00+10:00"))])
      travel_to(Time.zone.parse("2027-01-30T11:00:00+10:00"))
      sync_actions(gate, [scan_payload(ticket: ticket2, manifest: manifest, sequence: 4, kind: "admit", occurred_at: Time.zone.parse("2027-01-30T11:00:00+10:00"))])
      travel_to(Time.zone.parse("2027-01-30T12:00:00+10:00"))
      sync_actions(gate, [scan_payload(ticket: ticket2, manifest: manifest, sequence: 5, kind: "exit", occurred_at: Time.zone.parse("2027-01-30T12:00:00+10:00"))])
      # Ticket 1 is STILL inside on Day 1!

      # Day 2 (Jan 31): Ticket 1 being inside on Day 1 does NOT block Day 2 entry!
      travel_to(Time.zone.parse("2027-01-31T08:30:00+10:00"))
      manifest_day2 = fetch_manifest(gate)
      day2_entry = sync_actions(gate, [scan_payload(ticket: ticket, manifest: manifest_day2, sequence: 6, occurred_at: Time.zone.parse("2027-01-31T08:30:00+10:00"))])
      expect(day2_entry.dig("results", 0)).to include("result" => "accepted", "reason_code" => "admitted")
      expect(day2_entry.dig("summary", "live_headcount")).to eq(1)

      # Check organizer event stats endpoint has live headcount and per-day breakdown
      get "/api/v1/organizer/events/#{event.id}/stats", headers: headers
      expect(response).to have_http_status(:ok)
      expect(response.parsed_body).to include("live_headcount" => 1)
      expect(response.parsed_body.fetch("headcount_by_day").pluck("day")).to eq(["2027-01-30", "2027-01-31"])

      # Check reporting hub attendance report
      get "/api/v1/organizer/events/#{event.id}/reports", params: { report_type: "attendance" }, headers: headers
      expect(response).to have_http_status(:ok)
      re_entry = response.parsed_body.dig("attendance", "re_entry")
      expect(re_entry).to include(
        "mode" => "exit_scan",
        "entries" => 3,
        "exits" => 2,
        "re_entries" => 1,
        "peak_headcount" => 2
      )
      by_day = re_entry.fetch("by_day")
      expect(by_day.length).to eq(2)
      expect(by_day[0]).to include(
        "day" => "2027-01-30", "entries" => 2, "exits" => 2, "re_entries" => 1,
        "current_headcount" => 1, "peak_headcount" => 2, "peak_headcount_label" => "9:15 AM"
      )
      expect(by_day[1]).to include(
        "day" => "2027-01-31", "entries" => 1, "exits" => 0, "re_entries" => 0,
        "current_headcount" => 1, "peak_headcount" => 1, "peak_headcount_label" => "8:30 AM"
      )

      # Check CSV export includes per-day re-entry & peak headcount columns
      get "/api/v1/organizer/events/#{event.id}/reports/export.csv", params: { report_type: "attendance" }, headers: headers
      expect(response).to have_http_status(:ok)
      csv = CSV.parse(response.body.delete_prefix("\uFEFF"), headers: true)
      day_rows = csv.select { |row| row["Day"].present? }
      expect(day_rows.map { |r| r["Day"] }).to eq(["2027-01-30", "2027-01-31"])
      expect(day_rows[0]["Entries"]).to eq("2")
      expect(day_rows[0]["Exits"]).to eq("2")
      expect(day_rows[0]["Re-entries"]).to eq("1")
      expect(day_rows[0]["Peak headcount"]).to eq("2")
      expect(day_rows[0]["Peak headcount time"]).to eq("9:15 AM")
    end

    it "keeps multi-night pass child tickets independent per night with per-day headcount on the pass event" do
      day1_event = create(:event, :published, organizer_profile: profile, title: "Copa Day 1",
        timezone: "Pacific/Guam", re_entry_mode: "exit_scan",
        starts_at: Time.zone.parse("2027-01-30T08:00:00+10:00"), ends_at: Time.zone.parse("2027-01-30T20:00:00+10:00"))
      day2_event = create(:event, :published, organizer_profile: profile, title: "Copa Day 2",
        timezone: "Pacific/Guam", re_entry_mode: "exit_scan",
        starts_at: Time.zone.parse("2027-01-31T08:00:00+10:00"), ends_at: Time.zone.parse("2027-01-31T20:00:00+10:00"))
      pass_event = create(:event, :published, organizer_profile: profile, title: "Copa Weekend Pass",
        timezone: "Pacific/Guam", re_entry_mode: "exit_scan",
        starts_at: Time.zone.parse("2027-01-30T08:00:00+10:00"), ends_at: Time.zone.parse("2027-01-31T20:00:00+10:00"))
      pass_type = create(:ticket_type, event: pass_event, name: "2-Day Pass")
      TicketTypeIncludedEvent.create!(ticket_type: pass_type, included_event: day1_event, position: 0)
      TicketTypeIncludedEvent.create!(ticket_type: pass_type, included_event: day2_event, position: 1)
      pass_order = create(:order, event: pass_event, buyer_name: "Dashiell Pruitt")
      parent = create(:ticket, event: pass_event, order: pass_order, ticket_type: pass_type, attendee_name: "Dashiell Pruitt")
      children = Passes::Issuance.call(order: pass_order, parent_ticket: parent)
      day1_ticket = children.find { |c| c.event_id == day1_event.id }
      day2_ticket = children.find { |c| c.event_id == day2_event.id }

      travel_to(Time.zone.parse("2027-01-30T10:00:00+10:00"))
      d1 = create(:scanner_device, organization: organization, event: day1_event, user: owner, name: "Day 1 Gate")
      m1 = Admissions::ManifestBuilder.call(event: day1_event, actor: owner)
      Admissions::Reconciler.call(device: d1, actor: owner, actions: [{
        action_uuid: "pass-d1", kind: "admit", source: "online", sequence: 1,
        manifest_version: m1.version, occurred_at: Time.current.iso8601(6),
        ticket_id: day1_ticket.id, credential_hash: Digest::SHA256.hexdigest(day1_ticket.scan_credential)
      }])
      expect(day1_ticket.reload.occupancy_state).to eq("inside")

      travel_to(Time.zone.parse("2027-01-31T10:00:00+10:00"))
      d2 = create(:scanner_device, organization: organization, event: day2_event, user: owner, name: "Day 2 Gate")
      m2 = Admissions::ManifestBuilder.call(event: day2_event, actor: owner)
      res2 = Admissions::Reconciler.call(device: d2, actor: owner, actions: [{
        action_uuid: "pass-d2", kind: "admit", source: "online", sequence: 1,
        manifest_version: m2.version, occurred_at: Time.current.iso8601(6),
        ticket_id: day2_ticket.id, credential_hash: Digest::SHA256.hexdigest(day2_ticket.scan_credential)
      }])
      expect(res2.first.action).to be_result_accepted
      expect(day2_ticket.reload.occupancy_state).to eq("inside")

      report = Admissions::ReEntryReport.call(event: pass_event)
      expect(report[:by_day].map { |d| [d[:event_title], d[:entries], d[:current_headcount]] }).to eq([
        ["Copa Day 1", 1, 1],
        ["Copa Day 2", 1, 1]
      ])
    end

    it "counts direct GA tickets alongside multi-night pass nights in live headcount and re-entry reports" do
      day1_event = create(:event, :published, organizer_profile: profile, title: "Copa Night 1",
        timezone: "Pacific/Guam", re_entry_mode: "exit_scan",
        starts_at: Time.zone.parse("2027-01-30T08:00:00+10:00"), ends_at: Time.zone.parse("2027-01-30T20:00:00+10:00"))
      mixed_event = create(:event, :published, organizer_profile: profile, title: "Copa Mixed Event",
        timezone: "Pacific/Guam", re_entry_mode: "exit_scan",
        starts_at: Time.zone.parse("2027-01-30T08:00:00+10:00"), ends_at: Time.zone.parse("2027-01-31T20:00:00+10:00"))
      pass_type = create(:ticket_type, event: mixed_event, name: "2-Day Pass")
      ga_type = create(:ticket_type, event: mixed_event, name: "Single GA")
      TicketTypeIncludedEvent.create!(ticket_type: pass_type, included_event: day1_event, position: 0)

      pass_order = create(:order, event: mixed_event, buyer_name: "Pass Holder")
      parent = create(:ticket, event: mixed_event, order: pass_order, ticket_type: pass_type, attendee_name: "Pass Holder")
      day1_child = Passes::Issuance.call(order: pass_order, parent_ticket: parent).sole
      ga_order = create(:order, event: mixed_event, buyer_name: "GA Holder")
      ga_ticket = create(:ticket, event: mixed_event, order: ga_order, ticket_type: ga_type, attendee_name: "GA Holder")

      travel_to(Time.zone.parse("2027-01-30T10:00:00+10:00"))
      mixed_device = create(:scanner_device, organization: organization, event: mixed_event, user: owner, name: "Main Gate")
      mixed_manifest = Admissions::ManifestBuilder.call(event: mixed_event, actor: owner)
      Admissions::Reconciler.call(device: mixed_device, actor: owner, actions: [{
        action_uuid: "mixed-ga-1", kind: "admit", source: "online", sequence: 1,
        manifest_version: mixed_manifest.version, occurred_at: Time.current.iso8601(6),
        ticket_id: ga_ticket.id, credential_hash: Digest::SHA256.hexdigest(ga_ticket.scan_credential)
      }])
      expect(Admissions::Counts.call(event: mixed_event)[:live_headcount]).to eq(1)

      d1_device = create(:scanner_device, organization: organization, event: day1_event, user: owner, name: "Night 1 Gate")
      d1_manifest = Admissions::ManifestBuilder.call(event: day1_event, actor: owner)
      Admissions::Reconciler.call(device: d1_device, actor: owner, actions: [{
        action_uuid: "mixed-pass-1", kind: "admit", source: "online", sequence: 1,
        manifest_version: d1_manifest.version, occurred_at: Time.current.iso8601(6),
        ticket_id: day1_child.id, credential_hash: Digest::SHA256.hexdigest(day1_child.scan_credential)
      }])
      Admissions::Counts.expire_headcount_cache!(mixed_event)
      expect(Admissions::Counts.call(event: mixed_event)[:live_headcount]).to eq(2)
      report = Admissions::ReEntryReport.call(event: mixed_event)
      expect(report[:current_headcount]).to eq(2)
      expect(report[:entries]).to eq(2)
    end

    it "keeps overnight events (20:00-02:00) on one service day across midnight for anti-passback, exits, cooldown, cap, cutoff, and live headcount" do
      night_event = create(:event, :published,
        organizer_profile: profile,
        title: "Late Night Showcase",
        timezone: "Pacific/Guam",
        starts_at: Time.zone.parse("2027-05-01T20:00:00+10:00"),
        ends_at: Time.zone.parse("2027-05-02T02:00:00+10:00"),
        re_entry_mode: "exit_scan",
        re_entry_max_count: 1,
        re_entry_cutoff_time: "01:00")
      night_type = create(:ticket_type, event: night_event, name: "GA")
      night_order = create(:order, event: night_event, buyer_name: "Fenwick Abara")
      night_ticket = create(:ticket, event: night_event, order: night_order, ticket_type: night_type, attendee_name: "Fenwick Abara")

      travel_to(Time.zone.parse("2027-05-01T23:30:00+10:00"))
      post "/api/v1/organizer/events/#{night_event.id}/scanner_devices",
        params: { identifier: "night-gate-1", name: "Night Gate" }, headers: headers, as: :json
      expect(response).to have_http_status(:created)
      gate = ScannerDevice.find(response.parsed_body.fetch("id"))
      get "/api/v1/organizer/events/#{night_event.id}/scanner_devices/#{gate.id}/manifest", headers: headers
      manifest = response.parsed_body

      # Entry at 23:30 on May 1
      post "/api/v1/organizer/events/#{night_event.id}/scanner_devices/#{gate.id}/sync",
        params: { actions: [scan_payload(ticket: night_ticket, manifest: manifest, sequence: 1, occurred_at: Time.current)] },
        headers: headers, as: :json
      expect(response.parsed_body.dig("results", 0)).to include("result" => "accepted", "reason_code" => "admitted")
      expect(response.parsed_body.dig("summary", "live_headcount")).to eq(1)

      # After midnight (00:05): live headcount MUST stay 1, and passback entry MUST be blocked
      travel_to(Time.zone.parse("2027-05-02T00:05:00+10:00"))
      expect(Admissions::Counts.call(event: night_event)[:live_headcount]).to eq(1)
      get "/api/v1/organizer/events/#{night_event.id}/stats", headers: headers
      expect(response.parsed_body.fetch("live_headcount")).to eq(1)

      post "/api/v1/organizer/events/#{night_event.id}/scanner_devices/#{gate.id}/sync",
        params: { actions: [scan_payload(ticket: night_ticket, manifest: manifest, sequence: 2, occurred_at: Time.current)] },
        headers: headers, as: :json
      expect(response.parsed_body.dig("results", 0)).to include("result" => "conflict", "reason_code" => "already_inside")

      # Exit at 00:10 MUST succeed (not "Not inside")
      travel_to(Time.zone.parse("2027-05-02T00:10:00+10:00"))
      post "/api/v1/organizer/events/#{night_event.id}/scanner_devices/#{gate.id}/sync",
        params: { actions: [scan_payload(ticket: night_ticket, manifest: manifest, sequence: 3, kind: "exit", occurred_at: Time.current)] },
        headers: headers, as: :json
      expect(response.parsed_body.dig("results", 0)).to include("result" => "accepted", "reason_code" => "exited")
      expect(response.parsed_body.dig("summary", "live_headcount")).to eq(0)

      # Re-entry at 00:30 (before 01:00 cutoff, cap=1) MUST succeed as re_entered
      travel_to(Time.zone.parse("2027-05-02T00:30:00+10:00"))
      post "/api/v1/organizer/events/#{night_event.id}/scanner_devices/#{gate.id}/sync",
        params: { actions: [scan_payload(ticket: night_ticket, manifest: manifest, sequence: 4, kind: "admit", occurred_at: Time.current)] },
        headers: headers, as: :json
      expect(response.parsed_body.dig("results", 0)).to include("result" => "accepted", "reason_code" => "re_entered")
      expect(night_ticket.reload.re_entry_count).to eq(1)

      # Exit at 00:40 and attempt 2nd re-entry at 00:45 -> cap=1 still enforced after midnight!
      travel_to(Time.zone.parse("2027-05-02T00:40:00+10:00"))
      post "/api/v1/organizer/events/#{night_event.id}/scanner_devices/#{gate.id}/sync",
        params: { actions: [scan_payload(ticket: night_ticket, manifest: manifest, sequence: 5, kind: "exit", occurred_at: Time.current)] },
        headers: headers, as: :json
      travel_to(Time.zone.parse("2027-05-02T00:45:00+10:00"))
      post "/api/v1/organizer/events/#{night_event.id}/scanner_devices/#{gate.id}/sync",
        params: { actions: [scan_payload(ticket: night_ticket, manifest: manifest, sequence: 6, kind: "admit", occurred_at: Time.current)] },
        headers: headers, as: :json
      expect(response.parsed_body.dig("results", 0)).to include("result" => "rejected", "reason_code" => "re_entry_limit_reached")

      # Raise cap and jump past 01:00 cutoff (01:15) -> blocked by cutoff!
      night_event.update!(re_entry_max_count: 5)
      travel_to(Time.zone.parse("2027-05-02T01:15:00+10:00"))
      post "/api/v1/organizer/events/#{night_event.id}/scanner_devices/#{gate.id}/sync",
        params: { actions: [scan_payload(ticket: night_ticket, manifest: manifest, sequence: 7, kind: "admit", occurred_at: Time.current)] },
        headers: headers, as: :json
      expect(response.parsed_body.dig("results", 0)).to include("result" => "rejected", "reason_code" => "re_entry_cutoff_passed")

      # Cooldown mode also does NOT reset at 00:01 on an overnight event
      cool_ticket = create(:ticket, event: night_event, order: night_order, ticket_type: night_type, attendee_name: "Greer Halvorsen")
      night_event.update!(re_entry_mode: "cooldown", re_entry_cooldown_minutes: 15, re_entry_cutoff_time: nil)
      travel_to(Time.zone.parse("2027-05-01T23:55:00+10:00"))
      get "/api/v1/organizer/events/#{night_event.id}/scanner_devices/#{gate.id}/manifest", headers: headers
      manifest_cool = response.parsed_body
      post "/api/v1/organizer/events/#{night_event.id}/scanner_devices/#{gate.id}/sync",
        params: { actions: [scan_payload(ticket: cool_ticket, manifest: manifest_cool, sequence: 8, occurred_at: Time.current)] },
        headers: headers, as: :json
      expect(response.parsed_body.dig("results", 0)).to include("result" => "accepted", "reason_code" => "admitted")

      travel_to(Time.zone.parse("2027-05-02T00:01:00+10:00"))
      post "/api/v1/organizer/events/#{night_event.id}/scanner_devices/#{gate.id}/sync",
        params: { actions: [scan_payload(ticket: cool_ticket, manifest: manifest_cool, sequence: 9, occurred_at: Time.current)] },
        headers: headers, as: :json
      expect(response.parsed_body.dig("results", 0)).to include("result" => "conflict", "reason_code" => "cooldown_active")
    end

    it "applies per-service-day re_entry_cutoff_time independently on Day 1 and Day 2 of a multi-day event" do
      event.update!(re_entry_mode: "exit_scan", re_entry_cutoff_time: "21:00")
      travel_to(Time.zone.parse("2027-01-30T18:00:00+10:00"))
      gate = register_device(user: owner, identifier: "cutoff-multi", name: "Main Gate")
      manifest = fetch_manifest(gate)

      # Day 1: enter at 18:00, exit at 19:00, re-entry at 21:30 -> blocked by 21:00 cutoff
      sync_actions(gate, [scan_payload(ticket: ticket, manifest: manifest, sequence: 1, occurred_at: Time.current)])
      travel_to(Time.zone.parse("2027-01-30T19:00:00+10:00"))
      day1_exit = sync_actions(gate, [scan_payload(ticket: ticket, manifest: manifest, sequence: 2, kind: "exit", occurred_at: Time.current)])
      expect(day1_exit.dig("results", 0)).to include("result" => "accepted", "reason_code" => "exited")
      travel_to(Time.zone.parse("2027-01-30T21:30:00+10:00"))
      day1_late = sync_actions(gate, [scan_payload(ticket: ticket, manifest: manifest, sequence: 3, kind: "admit", occurred_at: Time.current)])
      expect(day1_late.dig("results", 0)).to include("result" => "rejected", "reason_code" => "re_entry_cutoff_passed")

      # Day 2: enter at 10:00, exit at 12:00, re-enter at 14:00 -> ALLOWED (before Day 2's 21:00 cutoff!)
      travel_to(Time.zone.parse("2027-01-31T10:00:00+10:00"))
      gate = register_device(user: owner, identifier: "cutoff-multi", name: "Main Gate")
      manifest2 = fetch_manifest(gate)
      d2_in = sync_actions(gate, [scan_payload(ticket: ticket, manifest: manifest2, sequence: 4, kind: "admit", occurred_at: Time.current)])
      expect(d2_in.dig("results", 0)).to include("result" => "accepted", "reason_code" => "admitted")

      travel_to(Time.zone.parse("2027-01-31T12:00:00+10:00"))
      sync_actions(gate, [scan_payload(ticket: ticket, manifest: manifest2, sequence: 5, kind: "exit", occurred_at: Time.current)])

      travel_to(Time.zone.parse("2027-01-31T14:00:00+10:00"))
      d2_reenter = sync_actions(gate, [scan_payload(ticket: ticket, manifest: manifest2, sequence: 6, kind: "admit", occurred_at: Time.current)])
      expect(d2_reenter.dig("results", 0)).to include("result" => "accepted", "reason_code" => "re_entered")

      # Day 2 at 21:30 -> blocked by Day 2's 21:00 cutoff
      travel_to(Time.zone.parse("2027-01-31T20:00:00+10:00"))
      sync_actions(gate, [scan_payload(ticket: ticket, manifest: manifest2, sequence: 7, kind: "exit", occurred_at: Time.current)])
      travel_to(Time.zone.parse("2027-01-31T21:30:00+10:00"))
      d2_late = sync_actions(gate, [scan_payload(ticket: ticket, manifest: manifest2, sequence: 8, kind: "admit", occurred_at: Time.current)])
      expect(d2_late.dig("results", 0)).to include("result" => "rejected", "reason_code" => "re_entry_cutoff_passed")
    end

    it "surfaces untracked pre-re-entry check-ins so UI never displays a misleading zero" do
      legacy_ticket = create(:ticket, event: event, order: order, ticket_type: ticket_type, status: :checked_in, checked_in_at: 1.hour.ago, occupancy_state: "outside", occupancy_day: nil)
      expect(legacy_ticket.occupancy_day).to be_nil
      counts = Admissions::Counts.call(event: event)
      expect(counts[:untracked_pre_re_entry_admits]).to eq(1)
    end

    it "anchors single-session cutoffs past 05:00 to the first HH:MM at or after start/doors-open (22:00-07:00 cutoff 06:00 and 23:30-06:00 cutoff 05:30)" do
      late_event = create(:event,
        organization: organization, organizer_profile: profile, status: :published,
        starts_at: Time.zone.parse("2027-01-30T22:00:00+10:00"),
        ends_at: Time.zone.parse("2027-01-31T07:00:00+10:00"),
        timezone: "Pacific/Guam",
        re_entry_mode: "exit_scan",
        re_entry_cutoff_time: "06:00")
      tt = create(:ticket_type, event: late_event, price_cents: 2500)
      ord = create(:order, :completed, event: late_event)
      tk = create(:ticket, event: late_event, order: ord, ticket_type: tt, attendee_name: "Koa Reyes")

      travel_to(Time.zone.parse("2027-01-30T22:15:00+10:00"))
      post "/api/v1/organizer/events/#{late_event.id}/scanner_devices", params: { identifier: "rave-gate", name: "Main Gate" }, headers: headers, as: :json
      dev_id = response.parsed_body.fetch("id")
      get "/api/v1/organizer/events/#{late_event.id}/scanner_devices/#{dev_id}/manifest", headers: headers
      man = response.parsed_body
      entry = man.dig("payload", "tickets").find { |t| t["ticket_id"] == tk.id }
      ver = man.dig("payload", "version")

      # Enter 22:15, exit 23:00, re-enter 23:30 -> ALLOWED (cutoff is Jan 31 06:00, NOT Jan 30 06:00!)
      post "/api/v1/organizer/events/#{late_event.id}/scanner_devices/#{dev_id}/sync", params: {
        actions: [{ action_uuid: SecureRandom.uuid, kind: "admit", source: "online", sequence: 1, ticket_id: tk.id, credential_hash: entry["credential_hash"], manifest_version: ver, occurred_at: Time.current.iso8601 }]
      }, headers: headers, as: :json
      expect(response.parsed_body.dig("results", 0)).to include("result" => "accepted", "reason_code" => "admitted")

      travel_to(Time.zone.parse("2027-01-30T23:00:00+10:00"))
      post "/api/v1/organizer/events/#{late_event.id}/scanner_devices/#{dev_id}/sync", params: {
        actions: [{ action_uuid: SecureRandom.uuid, kind: "exit", source: "online", sequence: 2, ticket_id: tk.id, credential_hash: entry["credential_hash"], manifest_version: ver, occurred_at: Time.current.iso8601 }]
      }, headers: headers, as: :json
      expect(response.parsed_body.dig("results", 0)).to include("result" => "accepted", "reason_code" => "exited")

      travel_to(Time.zone.parse("2027-01-30T23:30:00+10:00"))
      post "/api/v1/organizer/events/#{late_event.id}/scanner_devices/#{dev_id}/sync", params: {
        actions: [{ action_uuid: SecureRandom.uuid, kind: "admit", source: "online", sequence: 3, ticket_id: tk.id, credential_hash: entry["credential_hash"], manifest_version: ver, occurred_at: Time.current.iso8601 }]
      }, headers: headers, as: :json
      expect(response.parsed_body.dig("results", 0)).to include("result" => "accepted", "reason_code" => "re_entered")

      # Exit at 05:30, re-enter at 05:45 -> still before 06:00, ALLOWED; exit at 05:55, re-enter at 06:15 -> REJECTED
      travel_to(Time.zone.parse("2027-01-31T05:30:00+10:00"))
      post "/api/v1/organizer/events/#{late_event.id}/scanner_devices/#{dev_id}/sync", params: {
        actions: [{ action_uuid: SecureRandom.uuid, kind: "exit", source: "online", sequence: 4, ticket_id: tk.id, credential_hash: entry["credential_hash"], manifest_version: ver, occurred_at: Time.current.iso8601 }]
      }, headers: headers, as: :json
      expect(response.parsed_body.dig("results", 0)).to include("result" => "accepted", "reason_code" => "exited")

      travel_to(Time.zone.parse("2027-01-31T05:45:00+10:00"))
      post "/api/v1/organizer/events/#{late_event.id}/scanner_devices/#{dev_id}/sync", params: {
        actions: [{ action_uuid: SecureRandom.uuid, kind: "admit", source: "online", sequence: 5, ticket_id: tk.id, credential_hash: entry["credential_hash"], manifest_version: ver, occurred_at: Time.current.iso8601 }]
      }, headers: headers, as: :json
      expect(response.parsed_body.dig("results", 0)).to include("result" => "accepted", "reason_code" => "re_entered")

      travel_to(Time.zone.parse("2027-01-31T05:55:00+10:00"))
      post "/api/v1/organizer/events/#{late_event.id}/scanner_devices/#{dev_id}/sync", params: {
        actions: [{ action_uuid: SecureRandom.uuid, kind: "exit", source: "online", sequence: 6, ticket_id: tk.id, credential_hash: entry["credential_hash"], manifest_version: ver, occurred_at: Time.current.iso8601 }]
      }, headers: headers, as: :json
      expect(response.parsed_body.dig("results", 0)).to include("result" => "accepted", "reason_code" => "exited")

      travel_to(Time.zone.parse("2027-01-31T06:15:00+10:00"))
      post "/api/v1/organizer/events/#{late_event.id}/scanner_devices/#{dev_id}/sync", params: {
        actions: [{ action_uuid: SecureRandom.uuid, kind: "admit", source: "online", sequence: 7, ticket_id: tk.id, credential_hash: entry["credential_hash"], manifest_version: ver, occurred_at: Time.current.iso8601 }]
      }, headers: headers, as: :json
      expect(response.parsed_body.dig("results", 0)).to include("result" => "rejected", "reason_code" => "re_entry_cutoff_passed")

      # Also verify 23:30-06:00 with cutoff 05:30 anchors to Jan 31 05:30
      late_event.update!(starts_at: Time.zone.parse("2027-01-30T23:30:00+10:00"), ends_at: Time.zone.parse("2027-01-31T06:00:00+10:00"), re_entry_cutoff_time: "05:30")
      expect(late_event.re_entry_cutoff_for_day(Date.new(2027, 1, 30))).to eq(Time.zone.parse("2027-01-31T05:30:00+10:00"))
    end

    it "treats a missing end time as start + 24 h so 23:00 and 04:00 events do not flip day at 05:00" do
      no_end_event = create(:event,
        organization: organization, organizer_profile: profile, status: :published,
        starts_at: Time.zone.parse("2027-01-30T23:00:00+10:00"),
        ends_at: nil,
        timezone: "Pacific/Guam",
        re_entry_mode: "exit_scan")
      tt = create(:ticket_type, event: no_end_event, price_cents: 2500)
      ord = create(:order, :completed, event: no_end_event)
      tk = create(:ticket, event: no_end_event, order: ord, ticket_type: tt, attendee_name: "Nalu Perez")

      travel_to(Time.zone.parse("2027-01-30T23:15:00+10:00"))
      post "/api/v1/organizer/events/#{no_end_event.id}/scanner_devices", params: { identifier: "no-end-gate", name: "Door A" }, headers: headers, as: :json
      dev_id = response.parsed_body.fetch("id")
      get "/api/v1/organizer/events/#{no_end_event.id}/scanner_devices/#{dev_id}/manifest", headers: headers
      man = response.parsed_body
      entry = man.dig("payload", "tickets").find { |t| t["ticket_id"] == tk.id }
      ver = man.dig("payload", "version")

      post "/api/v1/organizer/events/#{no_end_event.id}/scanner_devices/#{dev_id}/sync", params: {
        actions: [{ action_uuid: SecureRandom.uuid, kind: "admit", source: "online", sequence: 1, ticket_id: tk.id, credential_hash: entry["credential_hash"], manifest_version: ver, occurred_at: Time.current.iso8601 }]
      }, headers: headers, as: :json
      expect(response.parsed_body.dig("results", 0)).to include("result" => "accepted", "reason_code" => "admitted")

      # At 05:30 next morning: STILL same service day, STILL inside, headcount = 1, exit succeeds!
      travel_to(Time.zone.parse("2027-01-31T05:30:00+10:00"))
      expect(no_end_event.occupancy_day_for(Time.current)).to eq(Date.new(2027, 1, 30))
      expect(Admissions::Counts.call(event: no_end_event)[:live_headcount]).to eq(1)

      post "/api/v1/organizer/events/#{no_end_event.id}/scanner_devices/#{dev_id}/sync", params: {
        actions: [{ action_uuid: SecureRandom.uuid, kind: "admit", source: "online", sequence: 2, ticket_id: tk.id, credential_hash: entry["credential_hash"], manifest_version: ver, occurred_at: Time.current.iso8601 }]
      }, headers: headers, as: :json
      expect(response.parsed_body.dig("results", 0)).to include("result" => "conflict", "reason_code" => "already_inside")

      post "/api/v1/organizer/events/#{no_end_event.id}/scanner_devices/#{dev_id}/sync", params: {
        actions: [{ action_uuid: SecureRandom.uuid, kind: "exit", source: "online", sequence: 3, ticket_id: tk.id, credential_hash: entry["credential_hash"], manifest_version: ver, occurred_at: Time.current.iso8601 }]
      }, headers: headers, as: :json
      expect(response.parsed_body.dig("results", 0)).to include("result" => "accepted", "reason_code" => "exited")
      expect(response.parsed_body.dig("summary", "live_headcount")).to eq(0)

      # 04:00 start with no end time also stays on its start day at 05:30
      early_event = create(:event,
        organization: organization, organizer_profile: profile, status: :published,
        starts_at: Time.zone.parse("2027-01-30T04:00:00+10:00"),
        ends_at: nil,
        timezone: "Pacific/Guam",
        re_entry_mode: "exit_scan")
      expect(early_event.occupancy_day_for(Time.zone.parse("2027-01-30T05:30:00+10:00"))).to eq(Date.new(2027, 1, 30))
    end

    it "tolerates normal scanner clock skew (8 s and 30 s) on online/offline re-entries and exits, while flagging genuinely stale offline scans (>2 min)" do
      event.update!(re_entry_mode: "exit_scan")
      travel_to(Time.zone.parse("2027-01-30T18:00:00+10:00"))
      gate_a = register_device(user: owner, identifier: "gate-skew-a", name: "Gate A")
      gate_b = register_device(user: owner, identifier: "gate-skew-b", name: "Gate B")
      manifest = fetch_manifest(gate_a)

      # 1. Online entry at Gate A (18:00:00), online exit at Gate A (18:10:00)
      sync_actions(gate_a, [scan_payload(ticket: ticket, manifest: manifest, sequence: 1, occurred_at: Time.current)])
      travel_to(Time.zone.parse("2027-01-30T18:10:00+10:00"))
      sync_actions(gate_a, [scan_payload(ticket: ticket, manifest: manifest, sequence: 2, kind: "exit", occurred_at: Time.current)])
      expect(ticket.reload.occupancy_state).to eq("outside")

      # 2. Re-enter online at Gate B 5 s later, with Gate B's clock 8 s behind (18:09:57) -> ACCEPTED!
      travel_to(Time.zone.parse("2027-01-30T18:10:05+10:00"))
      preview_8s = preview_scan(gate_b, ticket: ticket, manifest: manifest, kind: "admit")
      expect(preview_8s).to include("status" => "ready", "re_entry" => true)
      skew_8s_online = sync_actions(gate_b, [
        scan_payload(ticket: ticket, manifest: manifest, sequence: 1, kind: "admit", source: "online",
          occurred_at: Time.zone.parse("2027-01-30T18:09:57+10:00"))
      ])
      expect(skew_8s_online.dig("results", 0)).to include("result" => "accepted", "reason_code" => "re_entered")
      expect(skew_8s_online.dig("summary", "live_headcount")).to eq(1)
      expect(ticket.reload).to have_attributes(occupancy_state: "inside", re_entry_conflict_flagged: false)

      # Guest's next exit succeeds (and tolerates Gate A's clock being 30 s fast on exit!)
      travel_to(Time.zone.parse("2027-01-30T18:12:00+10:00"))
      fast_exit = sync_actions(gate_a, [
        scan_payload(ticket: ticket, manifest: manifest, sequence: 3, kind: "exit", source: "online",
          occurred_at: Time.zone.parse("2027-01-30T18:12:30+10:00"))
      ])
      expect(fast_exit.dig("results", 0)).to include("result" => "accepted", "reason_code" => "exited")

      # 3. Exit scanner was 30 s fast (last_exit_at = 18:12:30), server clock is 18:12:05 -> online preview AND sync accept re-entry!
      travel_to(Time.zone.parse("2027-01-30T18:12:05+10:00"))
      preview_30s = preview_scan(gate_b, ticket: ticket, manifest: manifest, kind: "admit")
      expect(preview_30s).to include("status" => "ready", "re_entry" => true)
      skew_30s_online = sync_actions(gate_b, [
        scan_payload(ticket: ticket, manifest: manifest, sequence: 2, kind: "admit", source: "online", occurred_at: Time.current)
      ])
      expect(skew_30s_online.dig("results", 0)).to include("result" => "accepted", "reason_code" => "re_entered")

      # 4. Offline exit with 30 s backward clock skew (last_entry_at = 18:12:05, exit occurred_at = 18:11:35) -> ACCEPTED!
      travel_to(Time.zone.parse("2027-01-30T18:13:00+10:00"))
      skew_30s_offline_exit = sync_actions(gate_b, [
        scan_payload(ticket: ticket, manifest: manifest, sequence: 3, kind: "exit", source: "offline",
          occurred_at: Time.zone.parse("2027-01-30T18:11:35+10:00"))
      ])
      expect(skew_30s_offline_exit.dig("results", 0)).to include("result" => "accepted", "reason_code" => "exited")

      # 5. Offline admit with 8 s and 30 s backward skew (last_exit_at = 18:11:35, admit at 18:11:05) -> ACCEPTED!
      skew_30s_offline_admit = sync_actions(gate_b, [
        scan_payload(ticket: ticket, manifest: manifest, sequence: 4, kind: "admit", source: "offline",
          occurred_at: Time.zone.parse("2027-01-30T18:11:05+10:00"))
      ])
      expect(skew_30s_offline_admit.dig("results", 0)).to include("result" => "accepted", "reason_code" => "re_entered")

      # 6. Mirror stale offline exit: 10 minutes before latest entry (18:11:05 -> exit at 18:01:05) -> CONFLICT & flagged!
      stale_offline_exit = sync_actions(gate_a, [
        scan_payload(ticket: ticket, manifest: manifest, sequence: 4, kind: "exit", source: "offline",
          occurred_at: Time.zone.parse("2027-01-30T18:01:05+10:00"))
      ])
      expect(stale_offline_exit.dig("results", 0)).to include("result" => "conflict", "reason_code" => "exit_before_latest_entry")
      expect(ticket.reload).to have_attributes(occupancy_state: "inside", re_entry_conflict_flagged: true)

      # 7. Online exit succeeds (even with 30 s backward clock skew vs last_entry_at), then genuinely stale offline admit 10 min before exit -> CONFLICT & flagged!
      ticket.update!(re_entry_conflict_flagged: false)
      travel_to(Time.zone.parse("2027-01-30T18:20:00+10:00"))
      sync_actions(gate_a, [scan_payload(ticket: ticket, manifest: manifest, sequence: 5, kind: "exit", source: "online", occurred_at: Time.current)])
      expect(Admissions::Counts.call(event: event)[:live_headcount]).to eq(0)

      travel_to(Time.zone.parse("2027-01-30T18:25:00+10:00"))
      stale_offline_admit = sync_actions(gate_b, [
        scan_payload(ticket: ticket, manifest: manifest, sequence: 5, kind: "admit", source: "offline",
          occurred_at: Time.zone.parse("2027-01-30T18:10:00+10:00"))
      ])
      expect(stale_offline_admit.dig("results", 0)).to include("result" => "conflict", "reason_code" => "admit_before_latest_exit")
      expect(stale_offline_admit.dig("summary", "live_headcount")).to eq(0)
      expect(ticket.reload).to have_attributes(occupancy_state: "outside", re_entry_conflict_flagged: true)
    end

    it "caches headcount_by_day briefly on sync while keeping authoritative live_headcount fresh" do
      event.update!(re_entry_mode: "exit_scan")
      travel_to(Time.zone.parse("2027-01-30T14:00:00+10:00"))
      memory_cache = ActiveSupport::Cache::MemoryStore.new
      allow(Rails).to receive(:cache).and_return(memory_cache)

      expect(Admissions::ReEntryReport).to receive(:call).once.and_call_original
      first_counts = Admissions::Counts.call(event: event)
      expect(first_counts[:live_headcount]).to eq(0)

      # Ticket checks in directly -> second call within 12s reuses cached by_day, yet live_headcount updates immediately!
      ticket.check_in!(occurred_at: Time.current)
      second_counts = Admissions::Counts.call(event: event)
      expect(second_counts[:live_headcount]).to eq(1)
    end
  end
end
