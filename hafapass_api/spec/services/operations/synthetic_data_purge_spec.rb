# frozen_string_literal: true

require "rails_helper"

RSpec.describe Operations::SyntheticDataPurge do
  let(:connection) { ActiveRecord::Base.connection }
  let!(:admin) { create(:user, :admin, email: "Ops@HafaPass.example", first_name: "Ops", clerk_id: "clerk_ops_admin") }
  let!(:second_kept) { create(:user, :organizer, email: "owner@hafapass.example") }
  let!(:attendee) { create(:user, email: "attendee@example.com") }
  let!(:organizer) { create(:user, :organizer, email: "organizer@example.com") }
  let!(:emailless) { create(:user, email: nil) }
  let(:out) { StringIO.new }

  before do
    SiteSetting.instance.update!(platform_name: "HafaPass Launch", platform_email: "hello@hafapass.example")
    seed_synthetic_graph
  end

  def seed_synthetic_graph
    profile = create(:organizer_profile, user: organizer)
    create(:organization_membership, organization: profile.organization, user: admin, role: :manager)
    event = create(:event, :published, organizer_profile: profile)
    ticket_type = create(:ticket_type, event: event)
    order = create(:order, event: event, user: attendee)
    create(:ticket, order: order, ticket_type: ticket_type, holder_user: attendee)
    payment = create(:payment, :succeeded, order: create(:order, :pending, event: event))
    create(:refund, order: payment.order, payment: payment, amount_cents: 500)
    create(:stripe_fee_evidence, payment: create(:payment, :succeeded))
    create(:message_delivery, order: order)
    create(:venue)
    create(:scanner_device, organization: profile.organization, event: event, user: organizer)
    create(:reconciliation_exception)
    WebhookEvent.create!(provider: "stripe", provider_event_id: "evt_test_1", event_type: "payment_intent.succeeded",
      payload: { "livemode" => false })
    AuditLogger.record!(action: "events.published", auditable: event, actor: organizer)
  end

  def all_counts
    connection.tables.sort.index_with { |table| connection.select_value("SELECT COUNT(*) FROM #{connection.quote_table_name(table)}").to_i }
  end

  def purge(confirm: described_class::CONFIRMATION, keep: "ops@hafapass.example, OWNER@hafapass.example ,")
    described_class.call(confirm: confirm, keep_user_emails: keep, out: out)
  end

  shared_examples "a refusal that changes nothing" do |message|
    it "refuses with a clear message and leaves every table untouched" do
      before = all_counts
      expect { run }.to raise_error(described_class::Refused, message)
      expect(all_counts).to eq(before)
      expect(out.string).to be_empty
    end
  end

  context "without the confirmation phrase" do
    let(:run) { purge(confirm: "yes") }

    include_examples "a refusal that changes nothing", /CONFIRM=PURGE_SYNTHETIC_DATA/
  end

  context "with blank KEEP_USER_EMAILS" do
    let(:run) { purge(keep: " , ") }

    include_examples "a refusal that changes nothing", /KEEP_USER_EMAILS is blank/
  end

  context "with a KEEP_USER_EMAILS entry that matches no user" do
    let(:run) { purge(keep: "ops@hafapass.example,typo@hafapass.example") }

    include_examples "a refusal that changes nothing", /no matching user: typo@hafapass.example/
  end

  context "when no kept user is a platform admin" do
    let(:run) { purge(keep: "owner@hafapass.example") }

    include_examples "a refusal that changes nothing", /keep at least one admin/
  end

  context "when a purge already ran" do
    before { AuditLogger.record!(action: described_class::ACTION, auditable: SiteSetting.instance) }

    let(:run) { purge }

    include_examples "a refusal that changes nothing", /already ran. Set ALLOW_REPEAT_PURGE=YES/

    it "runs again only with ALLOW_REPEAT_PURGE=YES" do
      described_class.call(confirm: described_class::CONFIRMATION, keep_user_emails: "ops@hafapass.example",
        allow_repeat: "YES", out: out)
      expect(Order.count).to eq(0)
    end
  end

  context "when payments are live" do
    before { SiteSetting.instance.update_column(:payment_mode, "live") }

    let(:run) { purge }

    include_examples "a refusal that changes nothing", /Payments are live/
  end

  context "when a kept table references a purged table" do
    before do
      allow_any_instance_of(described_class).to receive(:foreign_keys).and_return([%w[users organizations]])
    end

    let(:run) { purge }

    include_examples "a refusal that changes nothing", /Kept tables reference purged tables \(users -> organizations\)/
  end

  context "when a payment was charged in live mode" do
    before { create(:payment, :succeeded, provider_environment: "live") }

    let(:run) { purge }

    include_examples "a refusal that changes nothing", /1 payments charged in live mode/
  end

  context "when a livemode webhook event was received" do
    before do
      WebhookEvent.create!(provider: "stripe", provider_event_id: "evt_live_1", event_type: "charge.succeeded",
        payload: { "livemode" => true })
    end

    let(:run) { purge }

    include_examples "a refusal that changes nothing", /livemode webhook events/
  end

  context "when a settlement exists" do
    before { create(:settlement) }

    let(:run) { purge }

    include_examples "a refusal that changes nothing", /Settlement\/payout rows exist \(1 settlements\)/
  end

  context "when a payout exists" do
    before { create(:payout) }

    let(:run) { purge }

    include_examples "a refusal that changes nothing", /1 payouts/
  end

  context "with confirmation, valid kept users, and only synthetic data" do
    it "empties every business table, keeps the named users, settings, and infrastructure, and audits once" do
      settings_before = SiteSetting.instance.reload.attributes
      admin_before = admin.reload.attributes
      migrations_before = connection.select_value("SELECT COUNT(*) FROM schema_migrations").to_i
      expect(Order.count).to be_positive
      users_before = User.count
      audits_before = AuditLog.count

      result = purge

      kept = described_class::KEPT_TABLES + connection.tables.select { |t| t.start_with?(*described_class::KEPT_TABLE_PREFIXES) }
      (connection.tables - kept).each do |table|
        expected = table == "audit_logs" ? 1 : 0
        count = connection.select_value("SELECT COUNT(*) FROM #{connection.quote_table_name(table)}").to_i
        expect(count).to eq(expected), "expected #{table} to have #{expected} rows, found #{count}"
      end
      expect(result.purged_tables).to include("orders", "tickets", "payments", "refunds", "events", "organizations",
        "organization_memberships", "organizer_profiles", "venues", "scanner_devices", "webhook_events", "audit_logs")
      expect(result.purged_tables).not_to include("users", "site_settings", "schema_migrations", "solid_queue_jobs")

      expect(User.order(:id).pluck(:email)).to eq(["Ops@HafaPass.example", "owner@hafapass.example"])
      expect(admin.reload.attributes).to eq(admin_before)
      expect(admin).to be_admin
      expect(User.where(id: [attendee.id, organizer.id, emailless.id])).to be_empty
      expect(result.deleted_user_count).to eq(users_before - 2)
      expect(SiteSetting.count).to eq(1)
      expect(SiteSetting.instance.attributes).to eq(settings_before)
      expect(connection.select_value("SELECT COUNT(*) FROM schema_migrations").to_i).to eq(migrations_before)

      audit = AuditLog.sole
      expect(audit).to have_attributes(action: "operations.synthetic_data_purged", actor_user_id: nil,
        auditable: SiteSetting.instance)
      expect(audit.metadata).to include(
        "source" => "hafapass:purge_synthetic_data",
        "kept_user_emails" => ["Ops@HafaPass.example", "owner@hafapass.example"],
        "deleted_user_count" => users_before - 2
      )
      expect(audit.metadata["row_counts_before"]).to include("orders" => 3, "users" => users_before, "audit_logs" => audits_before)
      expect(audit.metadata["row_counts_after"]).to include("orders" => 0, "users" => 2, "audit_logs" => 0)
      expect(audit.metadata["purged_at"]).to be_present
    end

    it "keeps IDs increasing so email idempotency keys and job arguments never reuse an ID" do
      last_order_id = Order.maximum(:id)
      purge
      expect(create(:order).id).to be > last_order_id
    end

    it "deletes pending and failed queue jobs but keeps recurring tasks and their jobs" do
      pending = SolidQueue::Job.create!(queue_name: "default", class_name: "MessageDeliveryJob", arguments: { "arguments" => [1] },
        concurrency_key: "MessageDeliveryJob/1")
      recurring_job = SolidQueue::Job.create!(queue_name: "default", class_name: "RuntimeRecoveryJob", arguments: {})
      SolidQueue::RecurringExecution.create!(job_id: recurring_job.id, task_key: "runtime_recovery", run_at: Time.current)
      task = SolidQueue::RecurringTask.create!(key: "runtime_recovery_spec", schedule: "every minute", class_name: "RuntimeRecoveryJob")

      SolidQueue::Semaphore.find_or_create_by!(key: "MessageDeliveryJob/1") do |semaphore|
        semaphore.value = 0
        semaphore.expires_at = 1.hour.from_now
      end
      unless SolidQueue::BlockedExecution.exists?(job_id: pending.id)
        SolidQueue::ReadyExecution.where(job_id: pending.id).delete_all
        SolidQueue::BlockedExecution.create!(job_id: pending.id, queue_name: "default", priority: 0,
          concurrency_key: "MessageDeliveryJob/1", expires_at: 1.hour.from_now)
      end

      result = purge

      expect(SolidQueue::BlockedExecution.count).to eq(0)
      expect(SolidQueue::Semaphore.count).to eq(0)
      expect(SolidQueue::Job.where(id: pending.id)).to be_empty
      expect(SolidQueue::Job.where(id: recurring_job.id)).to exist
      expect(SolidQueue::RecurringTask.where(id: task.id)).to exist
      expect(result.deleted_queue_job_count).to be >= 1
      expect(AuditLog.sole.metadata["deleted_queue_job_count"]).to eq(result.deleted_queue_job_count)
    end

    it "prints a before/after summary" do
      users_before = User.count
      purge

      expect(out.string).to include("Purged", "kept users: Ops@HafaPass.example, owner@hafapass.example")
      expect(out.string).to match(/^orders\s+3\s+0$/)
      expect(out.string).to match(/^users\s+#{users_before}\s+2$/)
      expect(out.string).to match(/^TOTAL\s+\d+\s+3$/)
      expect(out.string).to include("Deleted #{users_before - 2} users and", "Wrote one operations.synthetic_data_purged audit log entry.")
    end
  end
end
