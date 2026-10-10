# frozen_string_literal: true

require "rails_helper"

RSpec.describe RuntimeRecoveryJob do
  around do |example|
    previous_profile = ENV["HAFAPASS_RUNTIME"]
    previous_adapter = ActiveJob::Base.queue_adapter
    ENV["HAFAPASS_RUNTIME"] = "embedded"
    ActiveJob::Base.queue_adapter = :solid_queue
    example.run
  ensure
    ENV["HAFAPASS_RUNTIME"] = previous_profile
    ActiveJob::Base.queue_adapter = previous_adapter
  end

  let(:order) { create(:order, :completed) }

  it "recovers a committed outbox row without a queue entry and avoids another entry while one is pending" do
    delivery = MessageDelivery.create!(order: order, event: order.event, template: "order_confirmation",
      recipient: order.buyer_email, provider: "simulated", idempotency_key: "outbox-crash")
    described_class.perform_now
    jobs = SolidQueue::Job.where(class_name: "MessageDeliveryJob")
    expect(jobs.count).to eq(1)
    expect(jobs.first.arguments["arguments"]).to eq([delivery.id])
    described_class.perform_now
    expect(jobs.count).to eq(1)
  end

  it "keeps the original unknown acceptance payload/key but does not replay after the provider fence expires" do
    delivery = MessageDelivery.create!(order: order, event: order.event, template: "order_confirmation",
      recipient: order.buyer_email, provider: "resend", idempotency_key: "immutable-key", attempts: 1,
      status: :failed, provider_outcome_unknown: true, provider_attempted_at: 24.hours.ago,
      outbound_payload: { "to" => order.buyer_email, "subject" => "Original", "html" => "Original" })
    expect { described_class.perform_now }.not_to change { SolidQueue::Job.where(class_name: "MessageDeliveryJob").count }
    expect(delivery.reload).to have_attributes(provider_outcome_unknown: true, idempotency_key: "immutable-key")
    expect(delivery.outbound_payload["subject"]).to eq("Original")
  end

  it "recovers overdue reminders whose delayed queue entry was lost" do
    reminder = create(:event_reminder, event: order.event, remind_at: 1.minute.ago)
    described_class.perform_now
    expect(SolidQueue::Job.find_by!(class_name: "EventReminderJob").arguments["arguments"])
      .to eq([reminder.id, reminder.remind_at.iso8601])
  end

  it "retries only safe jobs interrupted by a dead runner and preserves ordinary failures for review" do
    first = MessageDeliveryJob.perform_later(123)
    second = StripeProcessingFeeJob.perform_later(456)
    [first, second].each do |job|
      row = SolidQueue::Job.find_by!(active_job_id: job.job_id)
      row.ready_execution.destroy!
      SolidQueue::FailedExecution.create!(job: row, error: { exception_class: job == first ?
        "SolidQueue::Processes::ProcessPrunedError" : "StripeProcessingFees::EvidenceError", message: "fixture" })
    end
    described_class.perform_now
    expect(SolidQueue::Job.find_by!(active_job_id: first.job_id).ready_execution).to be_present
    expect(SolidQueue::Job.find_by!(active_job_id: second.job_id).failed_execution).to be_present
  end

  it "recovers orphaned claimed messages with the original acceptance identity" do
    delivery = MessageDelivery.create!(order: order, event: order.event, template: "order_confirmation",
      recipient: order.buyer_email, provider: "resend", idempotency_key: "lost-acceptance", attempts: 1,
      provider_outcome_unknown: true, provider_attempted_at: 1.minute.ago,
      outbound_payload: { "to" => order.buyer_email, "subject" => "Original", "html" => "Original" })
    job = MessageDeliveryJob.perform_later(delivery.id)
    row = SolidQueue::Job.find_by!(active_job_id: job.job_id)
    row.ready_execution.destroy!
    claim = SolidQueue::ClaimedExecution.new(job: row, process_id: nil)
    claim.save!(validate: false)
    SolidQueue::Supervisor.new(SolidQueue::Configuration.new).send(:fail_orphaned_executions)
    described_class.perform_now
    expect(row.reload.ready_execution).to be_present
    expect(delivery.reload.idempotency_key).to eq("lost-acceptance")
    expect(delivery.provider_outcome_unknown?).to be(true)
  end

  it "does not let fifty expired replay fences starve a later eligible outbox record" do
    50.times do |index|
      MessageDelivery.create!(order: order, event: order.event, template: "order_confirmation",
        recipient: order.buyer_email, provider: "resend", idempotency_key: "expired-#{index}", attempts: 1,
        provider_outcome_unknown: true, provider_attempted_at: 24.hours.ago)
    end
    eligible = MessageDelivery.create!(order: order, event: order.event, template: "order_confirmation",
      recipient: order.buyer_email, provider: "simulated", idempotency_key: "eligible")
    described_class.perform_now
    expect(SolidQueue::Job.find_by!(class_name: "MessageDeliveryJob").arguments["arguments"]).to eq([eligible.id])
  end

  it "reconciles a matching receipt after fifty unmatched receipts without resending accepted mail" do
    50.times do |index|
      MessageProviderEvent.create!(provider: "resend", provider_event_id: "orphan-#{index}",
        provider_message_id: "missing-#{index}", event_type: "email.delivered", occurred_at: Time.current,
        received_at: Time.current, payload: {})
    end
    delivery = MessageDelivery.create!(order: order, event: order.event, template: "order_confirmation",
      recipient: order.buyer_email, provider: "resend", idempotency_key: "accepted", status: :sent, provider_id: "accepted-id")
    receipt = MessageProviderEvent.create!(provider: "resend", provider_event_id: "matching", provider_message_id: "accepted-id",
      event_type: "email.delivered", occurred_at: Time.current, received_at: Time.current, payload: {})
    described_class.perform_now
    expect(receipt.reload.processed_at).to be_present
    expect(delivery.reload).to be_delivered
    expect(SolidQueue::Job.where(class_name: "MessageDeliveryJob")).to be_empty
  end

  it "recovers the current reminder schedule despite an obsolete future job for the same record" do
    reminder = create(:event_reminder, event: order.event, remind_at: 7.days.from_now)
    EventReminderJob.set(wait_until: reminder.remind_at).perform_later(reminder.id, reminder.remind_at.utc.iso8601)
    reminder.update!(remind_at: 1.minute.ago)
    described_class.perform_now
    args = SolidQueue::Job.where(class_name: "EventReminderJob").map { |job| job.arguments["arguments"] }
    expect(args).to include([reminder.id, reminder.remind_at.utc.iso8601])
    expect(args.length).to eq(2)
    described_class.perform_now
    expect(SolidQueue::Job.where(class_name: "EventReminderJob").count).to eq(2)
  end

  it "recovers an earlier campaign after a legacy future job outlives the reschedule commit" do
    campaign = CommunicationCampaign.create!(event: order.event, created_by_user: order.event.organizer_profile.user,
      name: "Fixture campaign", subject: "Fixture", body: "Synthetic", segment: { type: "all_attendees" },
      status: :scheduled, scheduled_at: 7.days.from_now)
    CommunicationCampaignJob.set(wait_until: campaign.scheduled_at).perform_later(campaign.id)
    campaign.update!(scheduled_at: 1.minute.ago)
    described_class.perform_now
    expected = [campaign.id, campaign.scheduled_at.utc.iso8601]
    expect(SolidQueue::Job.where(class_name: "CommunicationCampaignJob").map { |job| job.arguments["arguments"] }).to include(expected)
    described_class.perform_now
    expect(SolidQueue::Job.where(class_name: "CommunicationCampaignJob").count).to eq(2)
  end
end
