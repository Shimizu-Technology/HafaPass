require "rails_helper"

RSpec.describe "Api::V1::Admin::Maintenance", type: :request do
  let(:admin) { create(:user, :admin) }
  let(:organizer_profile) { create(:organizer_profile) }
  let(:headers) { auth_headers(admin) }

  describe "POST /api/v1/admin/maintenance/complete_past_events" do
    it "runs CompletePastEventsJob: completes events 6 hours after they end, with the admin as actor" do
      past_event = create(:event, :published, organizer_profile: organizer_profile, starts_at: 2.days.ago,
        ends_at: 2.days.ago + 3.hours, doors_open_at: 2.days.ago - 1.hour)
      just_ended = create(:event, :published, organizer_profile: organizer_profile, starts_at: 4.hours.ago,
        ends_at: 1.hour.ago, doors_open_at: 5.hours.ago)
      upcoming_event = create(:event, :published, organizer_profile: organizer_profile, starts_at: 3.days.from_now)
      allow(CompletePastEventsJob).to receive(:perform_now).and_call_original

      post "/api/v1/admin/maintenance/complete_past_events", headers: headers

      expect(response).to have_http_status(:ok)
      expect(response.parsed_body["message"]).to eq("Marked 1 past events as completed.")
      expect(CompletePastEventsJob).to have_received(:perform_now).with(actor: admin)
      expect(past_event.reload.status).to eq("completed")
      expect([just_ended, upcoming_event].map { |event| event.reload.status }).to eq(%w[published published])
      expect(past_event.event_state_changes.last).to have_attributes(action: "complete", actor_user: admin,
        reason: CompletePastEventsJob::REASON)
      expect(AuditLog.find_by!(action: "event.completed", auditable: past_event)).to have_attributes(actor_user_id: admin.id)
    end

    it "keeps completing other events when one fails" do
      broken = create(:event, :published, organizer_profile: organizer_profile, starts_at: 3.days.ago,
        ends_at: 3.days.ago + 3.hours, doors_open_at: 3.days.ago - 1.hour)
      good = create(:event, :published, organizer_profile: organizer_profile, starts_at: 2.days.ago,
        ends_at: 2.days.ago + 3.hours, doors_open_at: 2.days.ago - 1.hour)
      allow(EventLifecycle).to receive(:call).and_call_original
      allow(EventLifecycle).to receive(:call).with(hash_including(event: broken)).and_raise(ActiveRecord::StatementTimeout)
      allow(Sentry).to receive(:capture_exception)

      post "/api/v1/admin/maintenance/complete_past_events", headers: headers

      expect(response).to have_http_status(:ok)
      expect(response.parsed_body["message"]).to eq("Marked 1 past events as completed.")
      expect(good.reload).to be_completed
      expect(broken.reload).to be_published
    end

    it "requires admin access" do
      regular_user = create(:user)
      post "/api/v1/admin/maintenance/complete_past_events", headers: auth_headers(regular_user)
      expect(response).to have_http_status(:forbidden)
    end
  end
end
