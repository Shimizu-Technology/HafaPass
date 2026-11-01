# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Admin event unarchive", type: :request do
  let(:admin) { create(:user, :admin) }
  let(:profile) { create(:organizer_profile) }
  let(:event) { create(:event, :completed, organizer_profile: profile) }

  before do
    Settlements::Finalizer.call(event: event, actor: profile.user)
    EventLifecycle.call(event: event, action: :archive, actor: profile.user)
  end

  it "restores the status the event was archived from, with an audited reason" do
    post "/api/v1/admin/events/#{event.id}/unarchive", params: { reason: "Organizer archived too early" },
      headers: auth_headers(admin), as: :json

    expect(response).to have_http_status(:ok)
    expect(response.parsed_body).to include("id" => event.id, "status" => "completed")
    audit = AuditLog.find_by!(action: "event.unarchived", auditable: event)
    expect(audit).to have_attributes(actor_user_id: admin.id, source: "admin")
    expect(audit.after_data).to eq("status" => "completed")
  end

  it "requires an administrator and a reason of at most 1000 characters" do
    post "/api/v1/admin/events/#{event.id}/unarchive", params: { reason: "x" }, headers: auth_headers(profile.user), as: :json
    expect(response).to have_http_status(:forbidden)

    post "/api/v1/admin/events/#{event.id}/unarchive", params: { reason: " " }, headers: auth_headers(admin), as: :json
    expect(response).to have_http_status(:unprocessable_content)
    expect(response.parsed_body["error"]).to include("reason is required")
    expect(event.reload).to be_archived

    post "/api/v1/admin/events/#{event.id}/unarchive", params: { reason: "x" * 1001 }, headers: auth_headers(admin), as: :json
    expect(response).to have_http_status(:unprocessable_content)
    expect(response.parsed_body["error"]).to include("under 1000 characters")
    expect(event.reload).to be_archived
  end
end
