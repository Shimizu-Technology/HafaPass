# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Manager admission journal recovery", type: :request do
  include ActiveSupport::Testing::TimeHelpers
  let(:profile) { create(:organizer_profile) }
  let(:event) { create(:event, :published, organizer_profile: profile) }
  let(:organization) { event.organization }
  let(:manager) { profile.user }
  let(:staff) { create(:user) }
  let!(:membership) { create(:organization_membership, organization: organization, user: staff, role: :scanner) }
  let!(:assignment) { create(:event_staff_assignment, organization: organization, event: event, user: staff, role: :scanner) }
  let!(:ticket) { create(:ticket, event: event, order: create(:order, event: event), ticket_type: create(:ticket_type, event: event)) }
  let(:base) { "/api/v1/organizer/events/#{event.id}/scanner_devices" }
  let(:manager_headers) { auth_headers(manager).merge("X-Organization-Id" => organization.id.to_s) }
  let(:staff_headers) { auth_headers(staff).merge("X-Organization-Id" => organization.id.to_s) }

  before do
    travel_to(Time.current.change(usec: 0) - 1.minute)
    post base, params: { identifier: "retired-door", name: "North gate" }, headers: staff_headers
    expect(response).to have_http_status(:created)
    @device = ScannerDevice.find(response.parsed_body.fetch("id"))
    get "#{base}/#{@device.id}/manifest", headers: staff_headers
    expect(response).to have_http_status(:ok)
    @manifest = response.parsed_body
    @start = Time.current
    travel 10.seconds
    @input = { action_uuid: "retained-offline-scan", kind: "admit", source: "offline", sequence: 1,
      manifest_version: @manifest.dig("payload", "version"), occurred_at: Time.current.iso8601(6),
      ticket_id: ticket.id, credential_hash: Digest::SHA256.hexdigest(ticket.scan_credential) }
    travel 10.seconds
    @end = Time.current
    @device.revoke!
    travel 10.seconds
  end
  after { travel_back }

  def recover(actions: [@input], headers: manager_headers, **overrides)
    post "#{base}/#{@device.id}/recover", params: { actions: actions,
      reason: "North gate paper tally and staff handover independently checked",
      window_start: @start.iso8601(6), window_end: @end.iso8601(6) }.merge(overrides), headers: headers
  end

  it "recovers once under manager authority, audits review, and never restores revoked scanning" do
    post "#{base}/#{@device.id}/sync", params: { actions: [@input] }, headers: staff_headers
    expect(response).to have_http_status(:unprocessable_entity)
    expect(ticket.reload).to be_issued
    recover
    expect(response).to have_http_status(:ok)
    expect(response.parsed_body.dig("results", 0, "result")).to eq("accepted")
    expect(ticket.reload).to be_checked_in
    expect(@device.reload).to be_status_revoked
    expect(@device).not_to be_effective
    expect(@device.last_sequence).to eq(1)
    row = AuditLog.where(action: "scanner_device.journal_recovered").last!
    expect(row).to have_attributes(actor_user_id: manager.id, event_id: event.id, organization_id: organization.id)
    expect(row.metadata).to include("original_user_id" => staff.id, "action_uuids" => [@input[:action_uuid]])
    expect { recover }.not_to change(AdmissionAction, :count)
    expect(response).to have_http_status(:ok)
    get "#{base}/#{@device.id}/manifest", headers: staff_headers
    expect(response).to have_http_status(:forbidden)
    post base, params: { identifier: "retired-door", name: "North gate" }, headers: staff_headers
    expect(response).to have_http_status(:unprocessable_entity)
  end

  it "requires current manager authority, including after the manager loses membership" do
    recover(headers: staff_headers)
    expect(response).to have_http_status(:forbidden)
    organization.organization_memberships.find_by!(user: manager).update!(status: :revoked)
    recover
    expect(response).not_to have_http_status(:ok)
    expect(AdmissionAction).not_to exist
    expect(ticket.reload).to be_issued
  end

  it "rejects fabricated post-revocation times, unknown manifests, online scans and Undo without consuming sequence" do
    [@input.merge(occurred_at: @end.iso8601(6)), @input.merge(manifest_version: 999),
      @input.merge(source: "online"), @input.merge(kind: "reverse", reverses_action_uuid: "anything")].each do |input|
      recover(actions: [input])
      expect(response).to have_http_status(:unprocessable_entity)
      expect(AdmissionAction).not_to exist
      expect(@device.reload.last_sequence).to eq(0)
    end
    recover(window_start: 3.days.ago.iso8601, window_end: 2.days.ago.iso8601)
    expect(response).to have_http_status(:unprocessable_entity)
  end

  it "requires a download on the exact device, not merely knowledge of a valid event manifest" do
    @device = create(:scanner_device, event: event, organization: organization, user: staff)
    @device.revoke!
    recover
    expect(response).to have_http_status(:unprocessable_entity)
    expect(response.parsed_body.fetch("error")).to include("server-issued")
    expect(AdmissionAction).not_to exist
  end

  it "does not use a client backdate to bypass current cancellation or credential rotation" do
    ticket.rotate_scan_credential!
    recover
    expect(response).to have_http_status(:ok)
    expect(response.parsed_body.dig("results", 0)).to include("result" => "rejected", "reason_code" => "credential_revoked")
    expect(ticket.reload).to be_issued
    expect(AuditLog.where(action: "scanner_device.journal_recovered")).to exist
  end

  it "records a conflict when another gate already admitted the guest" do
    ticket.check_in!
    recover
    expect(response).to have_http_status(:ok)
    expect(response.parsed_body.dig("results", 0)).to include("result" => "conflict", "reason_code" => "already_admitted")
    expect(AuditLog.where(action: "scanner_device.journal_recovered")).to exist
  end

  it "rolls back the entire recovery if its required privileged audit fails" do
    allow(AuditLogger).to receive(:record!).and_call_original
    allow(AuditLogger).to receive(:record!).with(hash_including(action: "scanner_device.journal_recovered"))
      .and_raise(AuditLogger::WriteError, "synthetic required audit failure")
    expect { recover }.to raise_error(AuditLogger::WriteError)
    expect(ticket.reload).to be_issued
    expect(AdmissionAction).not_to exist
    expect(@device.reload.last_sequence).to eq(0)
  end

  it "separates membership loss from logical device retirement and historical manager recovery" do
    # A different ID still requires the same effective membership/assignment.
    post base, params: { identifier: "new-logical-id", name: "Replacement" }, headers: staff_headers
    expect(response).to have_http_status(:created)
    OrganizationTeam.revoke!(membership: membership, actor: manager)
    post base, params: { identifier: "another-id", name: "No authority" }, headers: staff_headers
    expect(response).not_to have_http_status(:created)
    post "#{base}/#{@device.id}/sync", params: { actions: [@input] }, headers: staff_headers
    expect(response).not_to have_http_status(:ok)
    recover
    expect(response).to have_http_status(:ok)
    expect(ticket.reload).to be_checked_in
    expect(membership.reload).to be_status_revoked
    expect(@device.reload).to be_status_revoked
  end

  it "recovers a scan before an expired lease without extending the lease" do
    @device.update!(status: :active, revoked_at: nil, authorization_expires_at: @end)
    post "#{base}/#{@device.id}/sync", params: { actions: [@input] }, headers: staff_headers
    expect(response).to have_http_status(:unprocessable_entity)
    recover
    expect(response).to have_http_status(:ok)
    expect(@device.reload).not_to be_effective
    renewed = Admissions::DeviceRegistrar.call(event: event, user: staff, identifier: @device.identifier, name: @device.name)
    expect(renewed).to be_effective
    expect(renewed.last_sequence).to eq(1)
  end
  it "does not extend historical proof when an expired lease is renewed later" do
    membership.update!(expires_at: 1.minute.from_now)
    device = Admissions::DeviceRegistrar.call(event: event, user: staff, identifier: "short-original-lease", name: "Short lease")
    get "#{base}/#{device.id}/manifest", headers: staff_headers
    expect(response).to have_http_status(:ok)
    old_expiry = device.authorization_expires_at
    @device = device
    travel_to(old_expiry + 10.seconds)
    membership.update!(expires_at: nil)
    Admissions::DeviceRegistrar.call(event: event, user: staff, identifier: device.identifier, name: device.name)
    @input[:occurred_at] = Time.current.iso8601(6)
    @end = Time.current + 1.second
    travel 2.seconds
    recover
    expect(response).to have_http_status(:unprocessable_entity)
    expect(response.parsed_body.fetch("error")).to include("server-issued")
    expect(ticket.reload).to be_issued
    expect(device.reload.last_sequence).to eq(0)
  end

  it "bounds recovery to the immutable staff revocation record as well as device revocation" do
    # Actual membership revocation writes the staff and membership audit trail.
    OrganizationTeam.revoke!(membership: membership, actor: manager)
    @device.update!(status: :active, revoked_at: nil)
    @input[:occurred_at] = Time.current.iso8601(6)
    @end = Time.current + 1.second
    travel 2.seconds
    recover
    expect(response).to have_http_status(:unprocessable_entity)
    expect(ticket.reload).to be_issued
    expect(@device.reload.last_sequence).to eq(0)
  end

  it "keeps recovery retries immutable and rejects a reused action with altered historical evidence" do
    recover
    expect(response).to have_http_status(:ok)
    recover(actions: [@input.merge(occurred_at: (Time.iso8601(@input[:occurred_at]) + 1.second).iso8601(6))])
    expect(response).to have_http_status(:unprocessable_entity)
    expect(AdmissionAction.count).to eq(1)
  end
  ["2026-10-26", "2026-10-26T08:00:00", "08:00:00+10:00", "2026-02-30T08:00:00+10:00",
    "2026-10-26T24:00:00Z", "2026-10-26T08:60:00Z", "2026-10-26T08:00:00+24:00", "nonsense"].each do |bound|
    it "refuses incomplete or invalid review bound #{bound.inspect} without mutation" do
      [:window_start, :window_end].each do |key|
        recover(**{ key => bound })
        expect(response).to have_http_status(:unprocessable_entity)
        expect(response.parsed_body.fetch("error")).to include("explicit ISO-8601")
        expect(AdmissionAction).not_to exist
        expect(AuditLog.where(action: "scanner_device.journal_recovered")).not_to exist
        expect(@device.reload.last_sequence).to eq(0)
      end
    end
  end

  it "accepts explicit Guam and UTC bounds as the same exact attested instants" do
    recover(window_start: @start.getlocal("+10:00").iso8601(6), window_end: @end.getlocal("+10:00").iso8601(6))
    expect(response).to have_http_status(:ok)
    audit = AuditLog.where(action: "scanner_device.journal_recovered").last!
    expect(Time.iso8601(audit.metadata.fetch("window_start"))).to eq(@start)
    expect(Time.iso8601(audit.metadata.fetch("window_end"))).to eq(@end)
    recover(window_start: @start.getutc.iso8601(6), window_end: @end.getutc.iso8601(6))
    expect(response).to have_http_status(:ok)
    expect(AdmissionAction.count).to eq(1)
  end

  it "queries immutable download and legacy lease evidence once per manifest in a multi-entry batch" do
    other = create(:ticket, event: event, order: create(:order, event: event), ticket_type: ticket.ticket_type)
    # The second ticket needs to be in the original signed manifest. Preserve
    # a real server-issued download, then emulate its supported legacy lease key.
    travel_to(@start + 1.second)
    @device.update!(status: :active, revoked_at: nil)
    get "#{base}/#{@device.id}/manifest", headers: staff_headers
    expect(response).to have_http_status(:ok)
    version = response.parsed_body.dig("payload", "version")
    download = AuditLog.where(auditable: @device, action: "scanner_device.manifest_downloaded").last!
    AuditLog.redact!(AuditLog.where(id: download.id), after_data: download.after_data.except("lease_expires_at"))
    # Historical legacy authorized records may predate the sanitizer's redaction.
    grant = AuditLog.where(auditable: @device, action: "scanner_device.authorized").last!
    AuditLog.redact!(AuditLog.where(id: grant.id), after_data: grant.after_data.merge("authorization_expires_at" => @device.authorization_expires_at.iso8601(6)))
    travel_to(@end)
    @device.revoke!
    travel 10.seconds
    first = @input.merge(manifest_version: version)
    second = first.merge(action_uuid: "second-retained", sequence: 2, ticket_id: other.id,
      credential_hash: Digest::SHA256.hexdigest(other.scan_credential))
    queries = []
    callback = ->(*args) { payload = args.last; queries << payload if payload[:sql].match?(/SELECT.*FROM "audit_logs"/) }
    ActiveSupport::Notifications.subscribed(callback, "sql.active_record") { recover(actions: [first, second]) }
    expect(response).to have_http_status(:ok), response.parsed_body.inspect
    expect(response.parsed_body.fetch("results").map { |row| row["result"] }).to eq(%w[accepted accepted])
    %w[scanner_device.manifest_downloaded scanner_device.authorized].each do |action|
      selected = queries.select { |row| row[:binds].any? { |bind| bind.respond_to?(:value_for_database) && bind.value_for_database == action } }
      expect(selected.size).to eq(1), "queries for #{action}: #{queries.map { |row| row[:sql] }}"
    end
    expect(@device.reload.last_sequence).to eq(2)
  end
end
