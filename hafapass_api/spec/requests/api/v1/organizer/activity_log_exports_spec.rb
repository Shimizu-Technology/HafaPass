# frozen_string_literal: true

require "rails_helper"
require "csv"

RSpec.describe "Activity CSV exports", type: :request do
  include ActiveSupport::Testing::TimeHelpers
  let(:profile) { create(:organizer_profile) }
  let(:organization) { profile.organization }
  let(:owner) { profile.user }
  let(:event) { create(:event, organizer_profile: profile, title: "=HYPERLINK(unsafe)") }
  let(:path) { "/api/v1/organizer/activity_log_exports" }

  def headers(person = owner)
    auth_headers(person).merge("X-Organization-Id" => organization.id.to_s)
  end

  def record(**attributes)
    AuditLogger.record!(action: "event.updated", auditable: event, actor: owner,
      before_data: { status: "draft", buyer_email: "buyer-secret@example.test" },
      after_data: { status: "published", internal_notes: "secret-note" },
      metadata: { search: "private-query", request_id: "secret-request" }, **attributes)
  end

  def request_export(person = owner, filters = {})
    post path, params: filters, headers: headers(person)
    expect(response).to have_http_status(:created), response.body
    response.parsed_body.fetch("export")
  end

  it "exports the identical authorized/redacted snapshot, escapes formulas and audits all successful stages" do
    log = record
    foreign = create(:event)
    AuditLogger.record!(action: "event.updated", auditable: foreign, actor: owner)
    item = request_export(owner, event_id: event.id)
    record # a later insert cannot appear in the snapshot
    get "#{path}/#{item.fetch('id')}", headers: headers
    expect(response.parsed_body.dig("export", "status")).to eq("ready")
    get item.fetch("download_url"), headers: headers
    expect(response).to have_http_status(:ok), response.body
    rows = CSV.parse(response.body.delete_prefix("\uFEFF"), headers: true)
    expect(rows.length).to eq(2) # event.created plus the explicit update
    update = rows.find { |row| row["Activity"] == "John Doe changed #{event.title} from draft to published." }
    expect(update["Event"]).to start_with("\t=")
    expect(update["What changed"]).to include("draft", "published")
    expect(response.body).not_to include("buyer-secret", "secret-note", "private-query", "secret-request", "Request ID", foreign.title)
    expect(AuditLog.where(actor_user: owner).where("action LIKE 'activity_log.export_%'").order(:id).pluck(:action))
      .to eq(%w[activity_log.export_requested activity_log.export_generated activity_log.export_downloaded])
    expect(AuditLog.where(action: "activity_log.export_generated").last.metadata).to include("row_count" => 2)
    expect(log.reload.after_data).to include("internal_notes" => "secret-note")
  end

  it "rechecks membership, role changes, tenant and requester at both status and download" do
    record
    item = request_export
    stranger = create(:organization_membership, organization: organization, role: :owner).user
    get item.fetch("download_url"), headers: headers(stranger)
    expect(response).to have_http_status(:not_found)
    membership = organization.organization_memberships.find_by!(user: owner)
    membership.update!(role: :manager)
    get item.fetch("download_url"), headers: headers
    expect(response).to have_http_status(:forbidden)
    membership.update!(status: :revoked)
    get "#{path}/#{item.fetch('id')}", headers: headers
    expect(response).to have_http_status(:forbidden)
  end

  it "rechecks expiry of event-manager grants" do
    person = create(:organization_membership, organization: organization, role: :marketer).user
    assignment = create(:event_staff_assignment, event: event, user: person, role: :manager)
    record
    item = request_export(person, event_id: event.id)
    assignment.update!(status: :revoked)
    get item.fetch("download_url"), headers: headers(person)
    expect(response).to have_http_status(:forbidden)
  end

  it "applies privacy/retention redaction at download rather than retaining an older CSV" do
    log = record
    item = request_export
    AuditLog.redact!(AuditLog.where(id: log.id), before_data: {}, after_data: {})
    get item.fetch("download_url"), headers: headers
    expect(response).to have_http_status(:ok)
    row = CSV.parse(response.body.delete_prefix("\uFEFF"), headers: true).find { |value| value["Activity"] == "John Doe updated #{event.title}." }
    expect(row["What changed"]).to be_blank
  end

  it "rejects expired and tampered tickets" do
    item = request_export
    get "#{path}/tampered/download", headers: headers
    expect(response).to have_http_status(:gone)
    travel 2.days do
      get item.fetch("download_url"), headers: headers
      expect(response).to have_http_status(:gone)
    end
  end

  it "records failures without returning partial success and exposes failed status" do
    record
    allow(SecureRandom).to receive(:uuid).and_return("12345678-1234-4123-8123-123456789012")
    item = request_export
    allow_any_instance_of(ActivityLogPresenter).to receive(:organization_json).and_raise(StandardError, "controlled failure")
    get item.fetch("download_url"), headers: headers
    expect(response.body).to include(SpreadsheetExport::INCOMPLETE_MARKER)
    expect(AuditLog.where(action: "activity_log.export_failed").last.outcome).to eq("failed")
    get "#{path}/#{item.fetch('id')}", headers: headers
    expect(response.parsed_body.dig("export", "status")).to eq("failed")
  end

  %i[manager finance].each do |role|
    it "projects only #{role} history into CSV" do
      person = create(:organization_membership, organization: organization, role: role).user
      record
      AuditLogger.record!(action: "refund.created", auditable: event, actor: owner)
      item = request_export(person)
      get item.fetch("download_url"), headers: headers(person)
      csv = response.body
      expect(csv).to include(role == :manager ? "John Doe changed #{event.title} from draft to published." : "John Doe requested refund ##{event.id}.")
      excluded = role == :manager ? "John Doe requested refund ##{event.id}." : "John Doe changed #{event.title} from draft to published."
      expect(csv).not_to include(excluded, "metadata", "buyer-secret")
    end
  end

  %i[marketer box_office scanner].each do |role|
    it "denies #{role} export access" do
      person = create(:organization_membership, organization: organization, role: role).user
      post path, headers: headers(person)
      expect(response).to have_http_status(:forbidden)
    end
  end
end
