# frozen_string_literal: true

require "rails_helper"

RSpec.describe OperationalAlertJob do
  include ActiveSupport::Testing::TimeHelpers

  around { |example| freeze_time { example.run } }

  before { allow(Sentry).to receive(:capture_message) }

  def expect_alert(signal, count)
    expect(Sentry).to have_received(:capture_message).with("Operational alert: #{signal}", level: :error,
      fingerprint: ["operational-alert", signal], tags: { operational_signal: signal }, extra: { count: count })
  end

  def failed_job(at)
    job = SolidQueue::Job.create!(class_name: "MessageDeliveryJob", queue_name: "emails", arguments: {}, priority: 0)
    SolidQueue::FailedExecution.create!(job: job, error: "{}", created_at: at)
  end

  it "is scheduled every five minutes in every runtime" do
    YAML.safe_load(Rails.root.join("config/recurring.yml").read, aliases: true).values_at("production", "test").each do |schedule|
      expect(schedule.fetch("operational_alerts")).to eq("class" => "OperationalAlertJob", "schedule" => "every 5 minutes")
    end
  end

  it "stays quiet when nothing needs a person" do
    described_class.perform_now
    expect(Sentry).not_to have_received(:capture_message)
  end

  it "alerts on deliveries that exhausted their attempts in the last day" do
    create(:message_delivery, status: :failed, attempts: 5, failed_at: 1.hour.ago)
    create(:message_delivery, status: :failed, attempts: 6, failed_at: 23.hours.ago)
    create(:message_delivery, status: :failed, attempts: 4, failed_at: 1.hour.ago)
    create(:message_delivery, status: :failed, attempts: 5, failed_at: 25.hours.ago)
    create(:message_delivery, status: :sent, attempts: 5, failed_at: 1.hour.ago)

    described_class.perform_now

    expect_alert("exhausted_message_deliveries", 2)
    expect(Sentry).to have_received(:capture_message).once
  end

  it "alerts on failed payment webhooks" do
    WebhookEvent.create!(provider: "stripe", provider_event_id: "evt_alert_failed", event_type: "payment_intent.succeeded", status: :failed)
    WebhookEvent.create!(provider: "stripe", provider_event_id: "evt_alert_done", event_type: "payment_intent.succeeded", status: :processed)

    described_class.perform_now

    expect_alert("failed_payment_webhooks", 1)
    expect(Sentry).to have_received(:capture_message).once
  end

  it "alerts on open reconciliation exceptions" do
    create(:reconciliation_exception, status: :open)
    create(:reconciliation_exception, status: :resolved)

    described_class.perform_now

    expect_alert("open_reconciliation_exceptions", 1)
    expect(Sentry).to have_received(:capture_message).once
  end

  it "alerts on background jobs that failed in the last hour" do
    failed_job(10.minutes.ago)
    failed_job(2.hours.ago)

    described_class.perform_now

    expect_alert("failed_background_jobs", 1)
    expect(Sentry).to have_received(:capture_message).once
  end

  it "raises each signal separately with its own fingerprint" do
    create(:reconciliation_exception, status: :open)
    failed_job(1.minute.ago)

    described_class.perform_now

    expect_alert("open_reconciliation_exceptions", 1)
    expect_alert("failed_background_jobs", 1)
    expect(Sentry).to have_received(:capture_message).twice
  end
end
