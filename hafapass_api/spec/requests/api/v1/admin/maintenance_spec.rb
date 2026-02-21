require "rails_helper"

RSpec.describe "Api::V1::Admin::Maintenance", type: :request do
  let(:admin) { create(:user, :admin) }
  let(:organizer_profile) { create(:organizer_profile) }
  let(:headers) { auth_headers(admin) }

  describe "POST /api/v1/admin/maintenance/complete_past_events" do
    it "marks past published events as completed" do
      past_event = create(:event, :published, organizer_profile: organizer_profile, starts_at: 2.days.ago)
      upcoming_event = create(:event, :published, organizer_profile: organizer_profile, starts_at: 3.days.from_now)

      post "/api/v1/admin/maintenance/complete_past_events", headers: headers

      expect(response).to have_http_status(:ok)
      expect(past_event.reload.status).to eq("completed")
      expect(upcoming_event.reload.status).to eq("published")
    end

    it "requires admin access" do
      regular_user = create(:user)
      post "/api/v1/admin/maintenance/complete_past_events", headers: auth_headers(regular_user)
      expect(response).to have_http_status(:forbidden)
    end
  end
end
