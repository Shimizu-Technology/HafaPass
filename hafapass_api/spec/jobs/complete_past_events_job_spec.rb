# frozen_string_literal: true

require "rails_helper"

RSpec.describe CompletePastEventsJob do
  let(:profile) { create(:organizer_profile) }
  let(:now) { Time.zone.parse("2026-11-02 12:00:00") }

  def event_ending(at, status: :published)
    create(:event, status, organizer_profile: profile, starts_at: at - 3.hours, ends_at: at,
      doors_open_at: at - 4.hours)
  end

  it "completes published events six hours after they end, as an audited system transition" do
    due = event_ending(now - 6.hours)
    recent = event_ending(now - 5.hours)
    upcoming = event_ending(now + 2.days)
    postponed = event_ending(now - 2.days, status: :postponed)

    expect(described_class.perform_now(now: now)).to eq(1)

    expect(due.reload).to be_completed
    expect([recent, upcoming, postponed].map { |event| event.reload.status }).to eq(%w[published published postponed])
    change = due.event_state_changes.sole
    expect(change).to have_attributes(action: "complete", from_status: "published", to_status: "completed",
      actor_user: nil, reason: described_class::REASON)
    audit = AuditLog.find_by!(action: "event.completed", auditable: due)
    expect(audit).to have_attributes(actor_user_id: nil, source: "system", outcome: "succeeded",
      organization_id: due.organization_id, event_id: due.id)
  end

  it "keeps going when one event fails and is idempotent on the next run" do
    broken = event_ending(now - 2.days)
    good = event_ending(now - 1.day)
    allow(EventLifecycle).to receive(:call).and_call_original
    allow(EventLifecycle).to receive(:call).with(hash_including(event: broken)).and_raise(ActiveRecord::StatementTimeout)
    allow(Sentry).to receive(:capture_exception)

    expect(described_class.perform_now(now: now)).to eq(1)
    expect(good.reload).to be_completed
    expect(broken.reload).to be_published
    expect(Sentry).to have_received(:capture_exception).with(instance_of(ActiveRecord::StatementTimeout), extra: { event_id: broken.id })

    expect(described_class.perform_now(now: now)).to eq(0)
    expect(good.event_state_changes.count).to eq(1)
  end

  it "is scheduled hourly and the rake task uses the same lifecycle path" do
    schedule = YAML.load_file(Rails.root.join("config/recurring.yml"), aliases: true)
    expect(schedule.dig("production", "complete_past_events")).to eq("class" => "CompletePastEventsJob", "schedule" => "every hour")

    due = event_ending(6.hours.ago - 1.minute)
    Rails.application.load_tasks unless Rake::Task.task_defined?("events:complete_past")
    expect { Rake::Task["events:complete_past"].execute }.to output(/Marked 1 past events as completed/).to_stdout
    expect(due.reload).to be_completed
    expect(due.event_state_changes.sole.actor_user).to be_nil
  end
end
