require "rails_helper"

RSpec.describe "Attendee marketplace preferences", type: :request do
  include ActiveSupport::Testing::TimeHelpers
  let(:user) { create(:user, email: "fan@example.com") }
  let(:event) { create(:event, :published, starts_at: 2.days.from_now, ends_at: 2.days.from_now + 2.hours) }
  let!(:ticket_type) { create(:ticket_type, event: event) }
  let(:headers) { auth_headers(user) }

  it "idempotently saves events and follows organizers" do
    2.times { post "/api/v1/me/event_favorites", params: { event_id: event.id }, headers: headers }
    2.times do
      post "/api/v1/me/organizer_follows", params: { organization_id: event.organization_id }, headers: headers
    end

    expect(user.event_favorites.count).to eq(1)
    expect(user.organizer_follows.count).to eq(1)

    get "/api/v1/me/event_favorites", headers: headers
    expect(response.parsed_body.fetch("events").first.fetch("id")).to eq(event.id)
  end

  it "schedules a durable reminder and ignores a stale schedule version" do
    expect {
      post "/api/v1/me/event_reminders", params: { event_id: event.id }, headers: headers
    }.to have_enqueued_job(EventReminderJob)
    reminder = user.event_reminders.find_by!(event: event)

    expect { EventReminderJob.perform_now(reminder.id, 3.hours.from_now.iso8601) }
      .not_to have_enqueued_job(MessageDeliveryJob)

    travel_to reminder.remind_at + 1.second do
      expect { EventReminderJob.perform_now(reminder.id, reminder.remind_at.iso8601) }
        .to have_enqueued_job(MessageDeliveryJob)
    end
    expect(reminder.reload).to be_pending
    MessageDeliveryJob.perform_now(MessageDelivery.find_by!(template: "event_reminder").id)
    expect(reminder.reload).to be_sent
  end
end
