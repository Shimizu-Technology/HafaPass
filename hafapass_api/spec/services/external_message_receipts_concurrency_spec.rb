require "rails_helper"
require "timeout"

RSpec.describe ExternalMessageReceipts, :webmock do
  self.use_transactional_tests = false

  def clean_test_data
    connection = ApplicationRecord.connection
    identity = connection.select_one("SELECT current_database() AS database, inet_server_addr()::text AS host")
    raise "Local test database required" unless Rails.env.test? && identity.fetch("database").end_with?("_test") &&
      ["127.0.0.1/32", "::1/128", "127.0.0.1", "::1", nil].include?(identity["host"])

    connection.execute("TRUNCATE audit_logs, audit_write_failures, users, events, message_deliveries, message_provider_events, site_settings RESTART IDENTITY CASCADE")
  end

  before { clean_test_data }
  after { clean_test_data }

  def setup_receipt(**attributes)
    @admin = create(:user, :admin)
    @receipt = MessageProviderEvent.create!({ provider: "resend", provider_event_id: "synthetic-event",
      provider_message_id: "synthetic-message", event_type: "email.delivered", occurred_at: 1.day.ago, received_at: 1.day.ago, payload: {} }.merge(attributes))
    @identity = @receipt.attributes.slice(*described_class::IDENTITY_KEYS)
  end

  def classify(reference = "receipt-origin:concurrency-proof")
    described_class.call(actor: @admin, receipts: [@identity], proof_reference: reference)
  end

  def worker(&block)
    Thread.new { ApplicationRecord.connection_pool.with_connection(&block) }.tap { |thread| thread.report_on_exception = false }
  end

  it "fails a competing decision closed while locked, then retries once and rejects conflicting evidence" do
    setup_receipt
    entered, release = Queue.new, Queue.new
    allow(AuditLogger).to receive(:record!).and_wrap_original do |original, **kwargs|
      entered << true
      release.pop
      original.call(**kwargs)
    end
    first = worker { classify }
    Timeout.timeout(5) { entered.pop }
    expect { worker { classify }.value }.to raise_error(ActiveRecord::LockWaitTimeout)
    release << true
    result = Timeout.timeout(5) { first.value }.sole
    allow(AuditLogger).to receive(:record!).and_call_original
    expect(worker { classify }.value.sole.id).to eq(result.id)
    expect { worker { classify("receipt-origin:other-proof") }.value }.to raise_error(described_class::Rejected)
    expect(AuditLog.where(action: described_class::MANUAL_ACTION).count).to eq(1)
  ensure
    release << true if release
    first&.join(5)
  end

  it "holds off a concurrent saved delivery ID until commit, then immediately restores review and normal processing" do
    setup_receipt
    delivery = create(:message_delivery, provider: "resend", provider_id: nil, status: :sent)
    entered, release, sender_pid = Queue.new, Queue.new, Queue.new
    allow(AuditLogger).to receive(:record!).and_wrap_original do |original, **kwargs|
      entered << true
      release.pop
      original.call(**kwargs)
    end
    decision = worker { classify }
    Timeout.timeout(5) { entered.pop }
    sender = worker do |connection|
      sender_pid << connection.select_value("SELECT pg_backend_pid()")
      MessageDelivery.find(delivery.id).update!(provider_id: @receipt.provider_message_id)
    end
    pid = Timeout.timeout(5) { sender_pid.pop }
    Timeout.timeout(5) do
      loop do
        break if ApplicationRecord.connection.select_value("SELECT wait_event_type FROM pg_stat_activity WHERE pid = #{Integer(pid)}") == "Lock"
        sleep 0.01
      end
    end
    release << true
    Timeout.timeout(5) { [decision, sender].each(&:value) }
    expect(AuditLog.where(action: described_class::MANUAL_ACTION).count).to eq(1)
    expect(described_class.resolved).to be_empty
    expect(OperationalReview.new.signals[:stale_message_events]).to eq(1)
    MessageProviderEventProcessor.reconcile_for!(delivery.reload)
    expect(@receipt.reload.message_delivery_id).to eq(delivery.id)
    expect(@receipt.processed_at).to be_present
    expect(delivery.reload).to be_delivered
  ensure
    release << true if release
    [decision, sender].compact.each { |thread| thread.join(5) }
  end

  it "rejects while a sender already owns a delivery write lock without creating an audit" do
    setup_receipt
    delivery = create(:message_delivery, provider: "resend", provider_id: nil)
    entered, release = Queue.new, Queue.new
    sender = worker do
      MessageDelivery.transaction do
        delivery.update!(provider_id: @receipt.provider_message_id)
        entered << true
        release.pop
      end
    end
    Timeout.timeout(5) { entered.pop }
    expect { classify }.to raise_error(ActiveRecord::LockWaitTimeout)
    expect(AuditLog.where(action: described_class::ACTIONS)).not_to exist
    release << true
    Timeout.timeout(5) { sender.value }
    expect { classify }.to raise_error(described_class::Rejected)
  ensure
    release << true if release
    sender&.join(5)
  end

  it "leaves already processed foreign-tagged HafaPass receipts alone while unrelated delivery writes are busy" do
    setup_receipt(payload: { "provenance" => { "application" => "csg_learn" } }, processed_at: Time.current)
    delivery = create(:message_delivery)
    entered, release = Queue.new, Queue.new
    sender = worker do
      MessageDelivery.transaction do
        delivery.update!(attempts: 1)
        entered << true
        release.pop
      end
    end
    Timeout.timeout(5) { entered.pop }
    expect { described_class.classify_verified_callback!(@receipt) }.not_to raise_error
    expect(AuditLog.where(action: described_class::ACTIONS)).not_to exist
  ensure
    release << true if release
    sender&.join(5)
  end

  it "rejects an enclosing snapshot isolation that could hide a newly committed provider ID" do
    setup_receipt
    MessageProviderEvent.transaction(isolation: :repeatable_read) do
      MessageProviderEvent.count # establish the snapshot before the service
      expect { classify }.to raise_error(described_class::Rejected, /read-committed/)
    end
    expect(AuditLog.where(action: described_class::ACTIONS)).not_to exist
  end
end
