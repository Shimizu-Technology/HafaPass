# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Admin activity filters and exports", type: :request do
  let(:admin) { create(:user, :admin) }
  let(:headers) { auth_headers(admin) }
  let(:event) { create(:event) }
  let(:path) { "/api/v1/admin/audit_logs" }

  it "combines exact organization, actor, action, event, outcome and source filters with registry area" do
    selected = AuditLogger.record!(action: "event.updated", auditable: event, actor: admin, source: "admin", outcome: "failed")
    AuditLogger.record!(action: "event.updated", auditable: event, actor: admin, source: "admin", outcome: "succeeded")
    get path, params: { organization_id: event.organization_id, actor_user_id: admin.id, action: "event.updated",
      event_id: event.id, outcome: "failed", source: "admin", area: "events" }, headers: headers
    expect(response).to have_http_status(:ok), response.body
    row = response.parsed_body.fetch("audit_logs").sole
    expect(row).to include("id" => selected.id, "sentence" => "Updated an event.", "action" => "event.updated")
    expect(row.dig("organization", "url")).to eq("/admin/organizations/#{event.organization_id}")
    expect(row.dig("event", "url")).to eq("/admin/events/#{event.id}")
    expect(response.parsed_body.dig("filters", "actions")).to include("event.updated")
    get path, params: { action: "event.update" }, headers: headers
    expect(response.parsed_body.fetch("audit_logs")).to be_empty
    get path, params: { actor_user_id: create(:user).id }, headers: headers
    expect(response.parsed_body.fetch("audit_logs")).to be_empty
  end

  it "exports sanitized technical detail for admins and requires admin status again at download" do
    AuditLogger.record!(action: "event.updated", auditable: event, actor: admin, metadata: { secret: "do-not-expose", count: 3 })
    post "/api/v1/admin/activity_log_exports", params: { action: "event.updated" }, headers: headers
    expect(response).to have_http_status(:created), response.body
    item = response.parsed_body.fetch("export")
    get item.fetch("download_url"), headers: headers
    expect(response).to have_http_status(:ok), response.body
    expect(response.body).to include("Action", "Request ID", "Technical details", "event.updated", "[redacted]")
    expect(response.body).not_to include("do-not-expose")
    expect(AuditLog.where(action: "activity_log.export_downloaded", actor_user: admin).last.source).to eq("admin")
    admin.update!(role: :support)
    get item.fetch("download_url"), headers: headers
    expect(response).to have_http_status(:forbidden)
  end
end
