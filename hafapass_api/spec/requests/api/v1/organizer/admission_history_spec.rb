# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Historical admission authority intervals", type: :request do
  include ActiveSupport::Testing::TimeHelpers

  before do
    @start = Time.current.change(usec: 0) - 4.hours
    travel_to(@start)
    @profile = create(:organizer_profile)
    @event = create(:event, :published, organizer_profile: @profile)
    @staff = create(:user)
    @member = create(:organization_membership, organization: @event.organization, user: @staff, role: :scanner)
    @assignment = create(:event_staff_assignment, organization: @event.organization, event: @event, user: @staff, role: :scanner)
    type = create(:ticket_type, event: @event)
    @tickets = 2.times.map { create(:ticket, event: @event, order: create(:order, event: @event), ticket_type: type) }
    @headers = auth_headers(@profile.user).merge("X-Organization-Id" => @event.organization_id.to_s)
    @staff_headers = auth_headers(@staff).merge("X-Organization-Id" => @event.organization_id.to_s)
    @base = "/api/v1/organizer/events/#{@event.id}"
  end
  after { travel_back }

  def member_update(role: @member.reload.role, expires_at: nil)
    patch "/api/v1/organizer/memberships/#{@member.id}", params: { role: role, expires_at: expires_at }, headers: @headers, as: :json
    expect(response).to have_http_status(:ok)
  end

  def assignment_update(expires_at: nil)
    patch "#{@base}/staff_assignments/#{@assignment.id}", params: { role: "scanner", expires_at: expires_at }, headers: @headers, as: :json
    expect(response).to have_http_status(:ok)
  end

  def download(legacy: false)
    allow(Admissions::HistoricalScanAuthority).to receive(:snapshot).and_return(nil) if legacy
    post "#{@base}/scanner_devices", params: { identifier: "historical-staff", name: "Historical gate" }, headers: @staff_headers
    expect(response).to have_http_status(:created)
    @device = ScannerDevice.find(response.parsed_body.fetch("id"))
    get "#{@base}/scanner_devices/#{@device.id}/manifest", headers: @staff_headers
    expect(response).to have_http_status(:ok)
    @manifest = response.parsed_body
    proof = AuditLog.where(auditable: @device, action: "scanner_device.manifest_downloaded").last!
    expect(proof.after_data.dig("scan_authority", "version")).to eq(1) unless legacy
  end

  def input(at, index: 0, sequence: 1)
    ticket = @tickets[index]
    { action_uuid: "history-#{index}-#{sequence}", kind: "admit", source: "offline", sequence: sequence,
      ticket_id: ticket.id, credential_hash: Digest::SHA256.hexdigest(ticket.scan_credential),
      manifest_version: @manifest.dig("payload", "version"), occurred_at: at.iso8601(6) }
  end

  def import(actions)
    post "#{@base}/scanner_devices/#{@device.id}/recover", params: { actions: actions,
      reason: "Manager independently reviewed original paper gate evidence", window_start: @start.iso8601(6),
      window_end: (Time.current - 1.second).iso8601(6) }, headers: @headers, as: :json
  end

  def retire_and_review
    travel_to(@start + 3.hours + 5.minutes)
    delete "#{@base}/scanner_devices/#{@device.id}", headers: @headers
    expect(response).to have_http_status(:no_content)
    travel_to(@start + 4.hours)
  end

  %w[membership_expiry assignment_expiry last_role legacy_expiry].each do |change|
    it "accepts before #{change}, rejects at/after and preserves its gap across a later re-grant" do
      member_update(role: "manager") if change == "last_role"
      if change == "last_role"
        delete "#{@base}/staff_assignments/#{@assignment.id}", headers: @headers
        expect(response).to have_http_status(:no_content)
      end
      download(legacy: change == "legacy_expiry")
      travel_to(@start + 1.hour)
      boundary = change == "last_role" ? Time.current : @start + 2.hours
      case change
      when "membership_expiry", "legacy_expiry" then member_update(expires_at: boundary.iso8601(6))
      when "assignment_expiry" then assignment_update(expires_at: boundary.iso8601(6))
      when "last_role" then member_update(role: "finance")
      end
      expect(AuditLog.where(action: change == "assignment_expiry" ? "event_staff.updated" : "organization.membership_updated")).to exist
      travel_to(@start + 3.hours)
      change == "assignment_expiry" ? assignment_update : member_update(role: change == "last_role" ? "manager" : "scanner")
      retire_and_review
      # Whole batch is refused before consuming any sequence/check-in, including
      # a valid first entry followed by one in the historical access gap.
      import([input(boundary - 1.second), input(boundary, index: 1, sequence: 2)])
      expect(response).to have_http_status(:unprocessable_entity)
      expect(@event.admission_actions).not_to exist
      expect(@event.tickets.checked_in).not_to exist
      expect(@device.reload.last_sequence).to eq(0)
      [boundary, boundary + 30.minutes].each do |at|
        import([input(at)])
        expect(response).to have_http_status(:unprocessable_entity)
        expect(@device.reload.last_sequence).to eq(0)
      end
      import([input(boundary - 1.second)])
      expect(response).to have_http_status(:ok)
      expect(response.parsed_body.dig("results", 0, "result")).to eq("accepted")
      expect(@tickets.first.reload).to be_checked_in
      expect(@device.reload).to be_status_revoked
      import([input(@start + 3.hours + 1.minute, index: 1, sequence: 2)])
      expect(response).to have_http_status(:ok)
      expect(@tickets.last.reload).to be_checked_in
    end
  end

  it "keeps an independent organization grant when a redundant assignment is revoked or expires" do
    member_update(role: "manager")
    download
    travel_to(@start + 1.hour)
    assignment_update(expires_at: (@start + 2.hours).iso8601(6))
    travel_to(@start + 2.hours + 1.minute)
    delete "#{@base}/staff_assignments/#{@assignment.id}", headers: @headers
    expect(response).to have_http_status(:no_content)
    retire_and_review
    import([input(@start + 2.hours + 30.minutes)])
    expect(response).to have_http_status(:ok)
    expect(@tickets.first.reload).to be_checked_in
  end

  it "keeps an independent event grant after an organization manager becomes finance" do
    member_update(role: "manager")
    download
    travel_to(@start + 1.hour)
    member_update(role: "finance")
    retire_and_review
    import([input(@start + 2.hours)])
    expect(response).to have_http_status(:ok)
    expect(@tickets.first.reload).to be_checked_in
  end

  it "fails closed when mutable grants change without immutable history" do
    download
    travel_to(@start + 1.hour)
    @member.update!(role: :finance) # Deliberately bypass the service audit.
    retire_and_review
    import([input(@start + 30.minutes)])
    expect(response).to have_http_status(:unprocessable_entity)
    expect(@event.admission_actions).not_to exist
    expect(@device.reload.last_sequence).to eq(0)
  end
  it "applies a past-dated expiry shortening when the server records it, not retroactively" do
    download
    travel_to(@start + 1.hour)
    member_update(expires_at: (@start + 30.minutes).iso8601(6))
    retire_and_review
    import([input(@start + 1.hour)])
    expect(response).to have_http_status(:unprocessable_entity)
    expect(@device.reload.last_sequence).to eq(0)
    import([input(@start + 59.minutes)])
    expect(response).to have_http_status(:ok)
    expect(@tickets.first.reload).to be_checked_in
  end
end
