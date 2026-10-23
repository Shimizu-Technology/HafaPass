# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Admin activity filters and exports", type: :request do
  let(:admin) { create(:user, :admin) }
  let(:headers) { auth_headers(admin) }
  let(:event) { create(:event) }
  let(:path) { "/api/v1/admin/audit_logs" }

  it "omits options on later pages and scopes first-page actor options to the current filters" do
    AuditLogger.record!(action: "event.updated", auditable: event, actor: admin)
    other = create(:user, :admin)
    AuditLogger.record!(action: "event.created", auditable: event, actor: other)
    get path, params: { action: "event.updated" }, headers: headers
    expect(response.parsed_body.dig("filters", "actors").pluck("id")).to eq([admin.id])
    get path, params: { page: 2, per_page: 1 }, headers: headers
    expect(response.parsed_body).not_to have_key("filters")
    expect(response).to have_http_status(:ok)
  end

  %w[organization_id actor_user_id event_id action].each do |filter|
    it "keeps #{filter} alternatives available and switches values while retaining other filters" do
      alternative_event = create(:event, organization: filter == "organization_id" ? create(:organization) : event.organization)
      alternative_actor = create(:user, :admin)
      first = AuditLogger.record!(action: "event.updated", auditable: event, actor: admin, source: "admin", outcome: "failed")
      second = AuditLogger.record!(action: filter == "action" ? "event.created" : "event.updated",
        auditable: %w[organization_id event_id].include?(filter) ? alternative_event : event,
        actor: filter == "actor_user_id" ? alternative_actor : admin, source: "admin", outcome: "failed")
      # This row must stay excluded by another active filter, including from options.
      excluded = AuditLogger.record!(action: "event.deleted", auditable: create(:event), actor: create(:user, :admin), source: "user")
      filters = { "organization_id" => event.organization_id, "actor_user_id" => admin.id,
        "event_id" => event.id, "action" => "event.updated", "source" => "admin", "outcome" => "failed", "area" => "events" }
      filters.delete("event_id") if filter == "organization_id"
      options_key = { "organization_id" => "organizations", "actor_user_id" => "actors", "event_id" => "events", "action" => "actions" }.fetch(filter)
      [first, second].each do |entry|
        get path, params: filters.merge(filter => entry.public_send(filter)), headers: headers
        expect(response).to have_http_status(:ok), response.body
        expect(response.parsed_body.fetch("audit_logs").pluck("id")).to eq([entry.id])
        options = response.parsed_body.dig("filters", options_key)
        values = filter == "action" ? options : options.pluck("id")
        expect(values).to contain_exactly(first.public_send(filter), second.public_send(filter))
        expect(values).not_to include(excluded.public_send(filter))
      end
    end
  end

  it "combines exact organization, actor, action, event, outcome and source filters with registry area" do
    selected = AuditLogger.record!(action: "event.updated", auditable: event, actor: admin, source: "admin", outcome: "failed")
    AuditLogger.record!(action: "event.updated", auditable: event, actor: admin, source: "admin", outcome: "succeeded")
    get path, params: { organization_id: event.organization_id, actor_user_id: admin.id, action: "event.updated",
      event_id: event.id, outcome: "failed", source: "admin", area: "events" }, headers: headers
    expect(response).to have_http_status(:ok), response.body
    row = response.parsed_body.fetch("audit_logs").sole
    expect(row).to include("id" => selected.id, "sentence" => "John Doe updated #{event.title}.", "action" => "event.updated")
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

RSpec.describe "Legacy unknown activity outcomes", type: :request do
  it "includes null historical outcomes and explicit unknown outcomes in admin lists and CSV" do
    admin = create(:user, :admin)
    event = create(:event)
    explicit = AuditLogger.record!(action: "event.updated", auditable: event, actor: admin, outcome: "unknown")
    # Reproduce a pre-integrity row. Historical NULL is intentional, not a
    # reconstructed outcome; the schema permits it for precisely this case.
    historical = AuditLog.new(action: "event.updated", auditable: event, event: event, organization: event.organization,
      actor_user: admin, source: nil, outcome: nil, occurred_at: 1.year.ago)
    historical.save!(validate: false)
    headers = auth_headers(admin)
    filters = { action: "event.updated", outcome: "unknown" }
    get "/api/v1/admin/audit_logs", params: filters, headers: headers
    expect(response).to have_http_status(:ok)
    expect(response.parsed_body.fetch("audit_logs").pluck("id")).to contain_exactly(explicit.id, historical.id)
    expect(response.parsed_body.fetch("audit_logs").pluck("outcome")).to eq(%w[unknown unknown])
    post "/api/v1/admin/activity_log_exports", params: filters, headers: headers
    get response.parsed_body.dig("export", "download_url"), headers: headers
    expect(response).to have_http_status(:ok)
    rows = CSV.parse(response.body.delete_prefix("\uFEFF"), headers: true)
    expect(rows.length).to eq(2)
    expect(rows.map { |row| row["Outcome"] }).to eq(%w[unknown unknown])
  end
end

RSpec.describe "Admin unknown action areas", type: :request do
  it "finds private unknown actions using their displayed platform fallback area" do
    admin = create(:user, :admin)
    entry = AuditLogger.record!(action: "unregistered.private_action", auditable: SiteSetting.instance, actor: admin)
    get "/api/v1/admin/audit_logs", params: { area: "platform", action: entry.action }, headers: auth_headers(admin)
    expect(response).to have_http_status(:ok)
    expect(response.parsed_body.fetch("audit_logs").pluck("id")).to eq([entry.id])
  end
end
