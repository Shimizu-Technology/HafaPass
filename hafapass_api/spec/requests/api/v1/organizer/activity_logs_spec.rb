# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Organization activity", type: :request do
  include ActiveSupport::Testing::TimeHelpers
  let(:profile) { create(:organizer_profile) }
  let(:organization) { profile.organization }
  let(:owner) { profile.user }
  let(:event) { create(:event, organizer_profile: profile) }
  let(:second_event) { create(:event, organizer_profile: profile) }
  let(:path) { "/api/v1/organizer/activity_logs" }

  def headers(person = owner)
    auth_headers(person).merge("X-Organization-Id" => organization.id.to_s)
  end

  def record(action, subject: event, actor: owner, **attributes)
    AuditLogger.record!(action: action, auditable: subject, actor: actor, organization: organization, **attributes)
  end

  def member(role)
    create(:organization_membership, organization: organization, role: role).user
  end

  def ids = response.parsed_body.fetch("activity_logs").pluck("id")

  it "starts with the selected tenant even when the actor also owns a different organization" do
    mine = record("event.updated")
    foreign = create(:event)
    create(:organization_membership, organization: foreign.organization, user: owner, role: :owner)
    hidden = AuditLogger.record!(action: "event.updated", auditable: foreign, actor: owner)
    get path, params: { organization_id: foreign.organization_id }, headers: headers
    expect(response).to have_http_status(:ok)
    expect(ids).to include(mine.id)
    expect(ids).not_to include(hidden.id)
    get path, headers: headers.merge("X-Organization-Id" => create(:organization).id.to_s)
    expect(response).to have_http_status(:forbidden)
  end

  it "uses only the registry audience, excludes unknown/private actions, and exposes only the display contract" do
    log = record("event.updated", before_data: { status: "draft", email: "buyer@example.test" },
      after_data: { status: "published", buyer_email: "buyer@example.test", internal_notes: "private-note" },
      metadata: { request_id: "private-request", ip_address: "10.1.2.3", search: "private-search", review_evidence: "private-evidence" })
    record("event.policy_hold_placed")
    record("event.unregistered")
    get path, headers: headers
    row = response.parsed_body.fetch("activity_logs").find { |item| item["id"] == log.id }
    expect(row.keys).to contain_exactly("id", "occurred_at", "sentence", "area", "outcome", "actor", "event", "target", "changes")
    expect(row["changes"]).to eq([{ "field" => "Status", "before" => "draft", "after" => "published" }])
    expect(row["sentence"]).to eq("Updated an event.")
    expect(row["actor"]).to include("email" => owner.email)
    expect(response.body).not_to match(/buyer@example|private-note|private-request|10\.1\.2\.3|private-search|private-evidence|policy_hold|unregistered/)
  end

  { manager: [true, false, false], finance: [false, true, false], marketer: nil, box_office: nil, scanner: nil }.each do |role, visibility|
    it "enforces #{role} audience and fields" do
      person = member(role)
      operations = record("event.updated")
      money = record("refund.created")
      team = record("organization.membership_updated", subject: organization)
      get path, headers: headers(person)
      if visibility
        expect(response).to have_http_status(:ok)
        [operations, money, team].zip(visibility).each do |entry, visible|
          expect(ids.include?(entry.id)).to eq(visible)
        end
        expect(response.body).not_to include("before_data", "metadata", "request_id", "ip_address")
      else
        expect(response).to have_http_status(:forbidden)
      end
    end
  end

  it "limits event-assigned managers to effective event assignments and rechecks expiry" do
    person = member(:marketer)
    assignment = create(:event_staff_assignment, event: event, user: person, role: :manager)
    mine = record("event.updated")
    hidden = record("event.updated", subject: second_event)
    finance = record("refund.created")
    global = record("venue_layout.updated", subject: organization)
    get path, headers: headers(person)
    expect(response).to have_http_status(:ok)
    expect(ids).to include(mine.id)
    expect(ids).not_to include(hidden.id, finance.id, global.id)
    options = response.parsed_body.fetch("filters")
    expect(options.fetch("events").pluck("id")).to eq([event.id])
    get path, params: { event_id: second_event.id }, headers: headers(person)
    expect(ids).to be_empty
    assignment.update!(expires_at: 1.minute.ago)
    get path, headers: headers(person)
    expect(response).to have_http_status(:forbidden)
  end

  it "masks platform staff and buyer contacts while labeling system/provider activity" do
    buyer = create(:user, email: "buyer-secret@example.test")
    staff = create(:user, :admin)
    rows = [record("event.updated", actor: staff, source: "admin"), record("event.updated", actor: nil, source: "system"),
      record("event.updated", actor: nil, source: "provider"), record("event.updated", actor: buyer, source: "user")]
    get path, headers: headers
    people = response.parsed_body.fetch("activity_logs").select { |row| rows.map(&:id).include?(row["id"]) }.map { |row| row["actor"] }
    expect(people).to contain_exactly({ "name" => "HåfaPass administrator" }, { "name" => "HåfaPass" }, { "name" => "Stripe" }, { "name" => "Buyer" })
    expect(response.body).not_to include(staff.email, buyer.email)
  end

  it "filters exact actor, event, area and outcome using Guam calendar boundaries" do
    selected = nil
    travel_to Time.iso8601("2026-10-22T14:05:00Z") do
      selected = record("event.updated", outcome: "failed")
    end
    record("event.updated", outcome: "succeeded")
    get path, params: { from: "2026-10-23", to: "2026-10-23", actor_user_id: owner.id,
      event_id: event.id, area: "events", outcome: "failed" }, headers: headers
    expect(response).to have_http_status(:ok)
    expect(ids).to eq([selected.id])
    get path, params: { from: "bad date" }, headers: headers
    expect(response).to have_http_status(:unprocessable_entity)
    get path, params: { outcome: "typo" }, headers: headers
    expect(response).to have_http_status(:unprocessable_entity)
  end

  it "searches authorized display text without searching private payloads or internal action keys" do
    log = record("event.updated", metadata: { internal_notes: "secret-needle" })
    get path, params: { q: "secret-needle" }, headers: headers
    expect(ids).to be_empty
    get path, params: { q: "event.updated" }, headers: headers
    expect(ids).to be_empty
    get path, params: { q: "Updated an event" }, headers: headers
    expect(ids).to include(log.id)
    get path, params: { q: event.title }, headers: headers
    expect(ids).to include(log.id)
    get path, params: { q: owner.email }, headers: headers
    expect(ids).to include(log.id)
  end

  it "uses a fixed snapshot and deterministic (occurred_at, id) cursor even with same-time inserts" do
    entries = []
    travel_to Time.current.change(usec: 123456) do
      5.times { entries << record("event.updated") }
      get path, params: { limit: 2 }, headers: headers
      first = ids
      cursor = response.parsed_body.dig("meta", "next_cursor")
      record("event.updated")
      all_ids = first
      while cursor
        get path, params: { limit: 2, cursor: cursor }, headers: headers
        expect(response).to have_http_status(:ok)
        all_ids += ids
        cursor = response.parsed_body.dig("meta", "next_cursor")
      end
      expect(all_ids.uniq).to eq(all_ids)
      expect(all_ids & entries.map(&:id)).to eq(entries.reverse.map(&:id))
    end
  end

  it "rejects cursor tampering/filter changes and caps the page at 100" do
    102.times { record("event.updated") }
    get path, params: { limit: 1000 }, headers: headers
    expect(ids.length).to eq(100)
    cursor = response.parsed_body.dig("meta", "next_cursor")
    get path, params: { cursor: cursor, area: "events" }, headers: headers
    expect(response).to have_http_status(:unprocessable_entity)
    get path, params: { cursor: "tampered" }, headers: headers
    expect(response).to have_http_status(:unprocessable_entity)
  end

  it "returns the persisted release marker without inferring it from first tenant activity" do
    old = record("event.updated")
    marker = AuditLogger.record!(action: "platform.activity_logging_started", auditable: organization, source: "system")
    current = record("event.updated")
    get path, headers: headers
    expect(Time.parse(response.parsed_body.dig("meta", "activity_logging_started_at"))).to be <= marker.occurred_at
    expect(ids).to include(current.id)
    expect(ids).not_to include(old.id)
  end
end

RSpec.describe "Activity former-member privacy", type: :request do
  it "masks invited, revoked and expired member contact in rows, actor options, search and CSV" do
    profile = create(:organizer_profile)
    organization = profile.organization
    event = create(:event, organizer_profile: profile)
    people = [
      create(:organization_membership, organization: organization, role: :scanner, status: :invited, accepted_at: nil).user,
      create(:organization_membership, organization: organization, role: :scanner, status: :revoked).user,
      create(:organization_membership, organization: organization, role: :scanner, expires_at: 1.hour.ago).user
    ]
    rows = people.map { |person| AuditLogger.record!(action: "event.updated", auditable: event, actor: person, source: "user") }
    headers = auth_headers(profile.user).merge("X-Organization-Id" => organization.id.to_s)
    get "/api/v1/organizer/activity_logs", headers: headers
    selected = response.parsed_body.fetch("activity_logs").select { |row| rows.map(&:id).include?(row["id"]) }
    expect(selected.map { |row| row["actor"] }).to eq([{ "name" => "Buyer" }] * 3)
    people.each { |person| expect(response.body).not_to include(person.email) }
    people.each do |person|
      get "/api/v1/organizer/activity_logs", params: { q: person.email }, headers: headers
      expect(response.parsed_body.fetch("activity_logs")).to be_empty
    end
    post "/api/v1/organizer/activity_log_exports", headers: headers
    url = response.parsed_body.dig("export", "download_url")
    get url, headers: headers
    expect(response).to have_http_status(:ok)
    people.each { |person| expect(response.body).not_to include(person.email) }
  end
end
