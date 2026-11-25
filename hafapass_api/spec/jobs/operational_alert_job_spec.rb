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

  describe "repeat alerts" do
    def open_exception
      create(:reconciliation_exception, status: :open)
    end

    def run_after(duration)
      travel(duration)
      described_class.perform_now
    end

    it "doesn't re-alert a standing count every run, but reminds every six hours while it stays non-zero" do
      open_exception
      described_class.perform_now
      expect(Sentry).to have_received(:capture_message).once

      alerted_at = Time.current
      run_after(5.minutes)
      run_after(5.hours + 54.minutes)
      expect(Sentry).to have_received(:capture_message).once

      run_after(1.minute)
      expect(Sentry).to have_received(:capture_message).twice
      expect(RuntimeAlertState.find("open_reconciliation_exceptions"))
        .to have_attributes(last_count: 1, last_alerted_at: alerted_at + 6.hours)
    end

    it "alerts again as soon as the count rises" do
      open_exception
      described_class.perform_now
      open_exception
      run_after(5.minutes)

      expect_alert("open_reconciliation_exceptions", 1)
      expect_alert("open_reconciliation_exceptions", 2)
      expect(Sentry).to have_received(:capture_message).twice
    end

    it "alerts on new failures after the count dropped, and right away after it cleared" do
      first = open_exception
      second = open_exception
      described_class.perform_now
      second.update!(status: :resolved)
      run_after(5.minutes)
      expect(Sentry).to have_received(:capture_message).once

      open_exception
      run_after(5.minutes)
      expect(Sentry).to have_received(:capture_message).twice

      ReconciliationException.update_all(status: ReconciliationException.statuses[:resolved])
      run_after(5.minutes)
      expect(RuntimeAlertState.find("open_reconciliation_exceptions").last_count).to eq(0)
      first.reload.update!(status: :open)
      run_after(5.minutes)
      expect(Sentry).to have_received(:capture_message).exactly(3).times
    end

    it "remembers alerts across job instances and only stores signals that have fired" do
      open_exception
      described_class.perform_now
      described_class.new.perform

      expect(Sentry).to have_received(:capture_message).once
      expect(RuntimeAlertState.pluck(:signal)).to eq(["open_reconciliation_exceptions"])
    end
  end

  describe "Stripe webhook signals" do
    def failed_receipt(at: 1.minute.ago, livemode: false)
      WebhookEvent.create!(provider: "stripe", provider_event_id: "evt_#{SecureRandom.hex(6)}", payload: { "livemode" => livemode },
        event_type: "payment_intent.succeeded", status: :failed, created_at: at, updated_at: at)
    end

    def processed_receipt(at: Time.current)
      WebhookEvent.create!(provider: "stripe", provider_event_id: "evt_#{SecureRandom.hex(6)}", payload: { "livemode" => false },
        event_type: "charge.updated", status: :processed, processed_at: at, created_at: at)
    end

    def run_after(duration)
      travel(duration)
      described_class.perform_now
    end

    it "alerts on a burst of failures with a stable fingerprint, tag and context, and not before the threshold" do
      2.times { failed_receipt }
      described_class.perform_now
      expect(Sentry).not_to have_received(:capture_message).with("Operational alert: stripe_webhook_failures", anything)

      failed_receipt
      described_class.perform_now
      expect(Sentry).to have_received(:capture_message).with("Operational alert: stripe_webhook_failures", level: :error,
        fingerprint: ["operational-alert", "stripe_webhook_failures"], tags: { operational_signal: "stripe_webhook_failures" },
        extra: { count: 3, mode: "test", window_minutes: 15, threshold: 3, stuck_processing: 0 })
    end

    it "alerts when a paid payment never got its webhook, and never during a quiet night" do
      described_class.perform_now
      expect(Sentry).not_to have_received(:capture_message)

      create(:payment, status: :succeeded, succeeded_at: 45.minutes.ago, provider_environment: "test")
      described_class.perform_now
      expect(Sentry).to have_received(:capture_message).with("Operational alert: stripe_webhooks_silent", level: :error,
        fingerprint: ["operational-alert", "stripe_webhooks_silent"], tags: { operational_signal: "stripe_webhooks_silent" },
        extra: hash_including(count: 1, paid_without_webhook: 1, silence_minutes: 30)).once
    end

    it "pages for rejected deliveries only when real deliveries look missing, with unverified wording" do
      3.times { Operations::WebhookRejections.record!(provider: "stripe", reason: "invalid_signature") }
      create(:payment, provider_environment: "test", created_at: 5.minutes.ago)
      described_class.perform_now
      expect(Sentry).to have_received(:capture_message).with("Operational alert: stripe_unverified_deliveries", level: :error,
        fingerprint: ["operational-alert", "stripe_unverified_deliveries"],
        tags: { operational_signal: "stripe_unverified_deliveries" },
        extra: hash_including(count: 3, rejected_in_window: 3, note: /Unverified rejected deliveries/)).once
    end

    it "does not send the 'no sign deliveries are missing' note in the same run it sends recovered" do
      3.times { Operations::WebhookRejections.record!(provider: "stripe", reason: "invalid_signature") }
      create(:payment, provider_environment: "test", created_at: 5.minutes.ago)
      described_class.perform_now                    # real deliveries look missing: pages
      expect(Sentry).to have_received(:capture_message).with("Operational alert: stripe_unverified_deliveries", anything).once

      travel(1.minute)
      processed_receipt                              # a verified delivery arrives; the rejections are still in the window
      described_class.perform_now

      expect(Sentry).to have_received(:capture_message).with("Operational alert recovered: stripe_unverified_deliveries", anything).once
      expect(Sentry).not_to have_received(:capture_message).with(/\AOperational note:/, anything)
    end

    it "records only an info note, never a page, for rejections with no sign deliveries are missing, and repeats it at most every 6 hours" do
      3.times { Operations::WebhookRejections.record!(provider: "stripe", reason: "invalid_signature") }
      described_class.perform_now
      expect(Sentry).not_to have_received(:capture_message).with(/Operational alert:/, anything)
      note = "Operational note: unverified rejected Stripe deliveries, no sign real deliveries are missing"
      expect(Sentry).to have_received(:capture_message).with(note, level: :info, fingerprint: ["operational-note", "stripe_unverified_deliveries"],
        tags: { operational_signal: "stripe_unverified_deliveries", operational_state: "note" }, extra: hash_including(count: 3)).once

      run_after(5.minutes)
      run_after(5.hours)
      expect(Sentry).to have_received(:capture_message).with(note, anything).once
    end

    it "dedupes: a standing incident repeats hourly, and extra evidence does not re-alert" do
      create(:payment, status: :succeeded, succeeded_at: 45.minutes.ago, provider_environment: "test")
      described_class.perform_now
      create(:payment, status: :succeeded, succeeded_at: 44.minutes.ago, provider_environment: "test")
      run_after(5.minutes)
      run_after(54.minutes)
      expect(Sentry).to have_received(:capture_message).with(/Operational alert: stripe_webhooks_silent/, anything).once

      run_after(1.minute)
      expect(Sentry).to have_received(:capture_message).with(/Operational alert: stripe_webhooks_silent/, anything).twice
    end

    it "says recovered only when a webhook was processed after the incident opened" do
      3.times { failed_receipt }
      described_class.perform_now
      WebhookEvent.failed.update_all(status: WebhookEvent.statuses[:processed], processed_at: Time.current + 1.minute)
      run_after(5.minutes)
      expect(Sentry).to have_received(:capture_message).with("Operational alert recovered: stripe_webhook_failures", level: :info,
        fingerprint: ["operational-alert-recovered", "stripe_webhook_failures"],
        tags: { operational_signal: "stripe_webhook_failures", operational_state: "recovered" }).once
      expect(RuntimeAlertState.find("stripe_webhook_failures").incident_opened_at).to be_nil

      run_after(5.minutes)
      expect(Sentry).to have_received(:capture_message).with(/\AOperational alert recovered/, anything).once
    end

    it "says quiet, not recovered, when failures merely age out of the window, and counts the rows left" do
      3.times { failed_receipt }
      described_class.perform_now
      run_after(20.minutes)
      expect(Sentry).not_to have_received(:capture_message).with(/\AOperational alert recovered/, anything)
      expect(Sentry).to have_received(:capture_message).with("Operational alert quiet, not confirmed recovered: stripe_webhook_failures",
        level: :info, fingerprint: ["operational-alert-quiet", "stripe_webhook_failures"],
        tags: { operational_signal: "stripe_webhook_failures", operational_state: "quiet" },
        extra: hash_including(unresolved_rows: 3)).once
    end

    it "pages again for a new incident after the previous one was confirmed quiet (a new burst is not lost inside the hourly cooldown)" do
      3.times { failed_receipt }
      described_class.perform_now                    # t0: page for burst 1
      run_after(20.minutes)                          # t20: burst 1 aged out -> quiet notice
      3.times { failed_receipt(at: Time.current) }
      run_after(5.minutes)                           # t25: burst 2 detected: pages again, not suppressed
      expect(Sentry).to have_received(:capture_message).with("Operational alert: stripe_webhook_failures", anything).twice

      run_after(20.minutes)                          # t45: burst 2 aged out -> its own quiet notice
      expect(Sentry).to have_received(:capture_message).with(/\AOperational alert quiet/, anything).twice
    end

    it "defers a re-open inside the storm guard but still pages once the guard passes if it stands" do
      3.times { failed_receipt }
      described_class.perform_now                    # page at t0
      travel(2.minutes)
      WebhookEvent.update_all(updated_at: 1.hour.ago) # burst 1 gone (rows stay failed)
      described_class.perform_now                    # quiet at t2
      3.times { failed_receipt(at: Time.current) }
      run_after(1.minute)                            # t3: reopened inside the 10-minute guard: deferred
      expect(Sentry).to have_received(:capture_message).with("Operational alert: stripe_webhook_failures", anything).once
      3.times { failed_receipt(at: Time.current) }
      run_after(8.minutes)                           # t11: guard passed, still failing: pages
      expect(Sentry).to have_received(:capture_message).with("Operational alert: stripe_webhook_failures", anything).twice
    end

    it "still says something when a deferred incident clears before it could be paged" do
      3.times { failed_receipt }
      described_class.perform_now
      travel(2.minutes)
      WebhookEvent.update_all(updated_at: 1.hour.ago)
      described_class.perform_now                    # quiet at t2
      3.times { failed_receipt(at: Time.current) }
      run_after(1.minute)                            # deferred at t3
      run_after(16.minutes)                          # clears at t19 unpaged
      expect(Sentry).to have_received(:capture_message).with(/\AOperational alert quiet/, hash_including(extra: hash_including(paged: false))).once
    end

    it "does not say recovered when an unrelated success arrives while the paid payment still lacks its success receipt" do
      create(:payment, status: :succeeded, succeeded_at: 45.minutes.ago, provider_environment: "test")
      described_class.perform_now
      travel(1.minute)
      processed_receipt                              # charge.updated after the incident opened: unrelated
      run_after(6.hours)                             # the payment ages out of the alert window, still unconfirmed
      expect(Sentry).not_to have_received(:capture_message).with(/\AOperational alert recovered/, anything)
      expect(Sentry).to have_received(:capture_message).with("Operational alert quiet, not confirmed recovered: stripe_webhooks_silent",
        hash_including(extra: hash_including(unresolved_rows: 1))).once
    end

    it "keeps a still-failing incident open and pages hourly while it stands" do
      3.times { failed_receipt(at: Time.current) }
      described_class.perform_now
      5.times do
        travel(14.minutes)
        3.times { failed_receipt(at: Time.current) }
        described_class.perform_now
      end
      expect(Sentry).to have_received(:capture_message).with("Operational alert: stripe_webhook_failures", anything).twice
    end

    it "sends no notice for the older signals when they clear" do
      create(:reconciliation_exception, status: :open)
      described_class.perform_now
      ReconciliationException.update_all(status: ReconciliationException.statuses[:resolved])
      run_after(5.minutes)
      expect(Sentry).not_to have_received(:capture_message).with(/recovered|quiet/, anything)
    end

    it "keeps live and test apart: test-mode failures never page in production" do
      allow(Rails).to receive(:env).and_return(ActiveSupport::EnvironmentInquirer.new("production"))
      3.times { failed_receipt(livemode: false) }
      described_class.perform_now
      expect(Sentry).not_to have_received(:capture_message).with(/stripe_webhook_failures/, anything)
    end

    it "isolates signals: one that raises is reported and the others still run" do
      create(:reconciliation_exception, status: :open)
      allow(WebhookEvent).to receive(:failed).and_raise(ActiveRecord::StatementInvalid, "boom")
      allow(Sentry).to receive(:capture_exception)

      described_class.perform_now

      expect(Sentry).to have_received(:capture_exception).with(an_instance_of(ActiveRecord::StatementInvalid),
        tags: hash_including(operational_signal: "failed_payment_webhooks", operational_state: "check_failed")).at_least(:once)
      expect_alert("open_reconciliation_exceptions", 1)
    end
  end
end
