# frozen_string_literal: true

require "rails_helper"
require "rake"

# Read-only A2 preflight (docs/NEVER_FULFILLED_RELEASE.md "A2 release"): the
# guards, the undisposed counts, custody completeness and the organizer
# payable audit of each event with a classified capture, with the action the
# guards leave open for each in-flight payout. Writes nothing.
RSpec.describe "never_fulfilled:a2_preflight" do
  before(:all) do
    Rails.application.load_tasks unless Rake::Task.task_defined?("never_fulfilled:a2_preflight")
  end

  let(:admin) { create(:user, :admin) }
  let(:profile) { create(:organizer_profile, :verified) }
  let(:organization) { profile.organization }
  let(:event) { create(:event, :completed, organization: organization, organizer_profile: profile) }
  let(:ticket_type) { create(:ticket_type, event: event, price_cents: 2000) }

  before do
    allow(StripeProcessingFees).to receive(:require_adjustment_review!)
    allow(PayoutGateway).to receive(:submit) { |payout| PayoutGateway::Result.new(provider_payout_id: "manual_po_#{payout.id}", status: :processing) }
    approved_bank_account!(organization, actor: profile.user, admin: admin)
  end

  def run_task
    task = Rake::Task["never_fulfilled:a2_preflight"]
    task.reenable
    captured = StringIO.new
    $stdout = captured
    task.invoke
    captured.string
  ensure
    $stdout = STDOUT
  end

  def lines(output, section) = output.lines.grep(/\Asection=#{section}\t/).map { |line| line.strip.split("\t").to_h { |pair| pair.split("=", 2) } }

  it "lists stale in-flight payouts and their action, the payable audit and the gates, and writes nothing" do
    record_card_sale!(event, ticket_type: ticket_type, quantity: 5)
    sent = PayoutCreator.call(settlement: Settlements::Finalizer.call(event: event, actor: admin), actor: admin,
      idempotency_key: "pf-sent", amount_cents: 2000)
    pending = PayoutCreator.new(settlement: Settlements::Finalizer.call(event: event, actor: admin), actor: admin,
      idempotency_key: "pf-pending", amount_cents: 1000).send(:reserve!).first
    order, payment, = classified_capture(items: [[1200, 160, 0, 0]], event: event)
    component = create(:fee_component, order: order, order_item: order.order_items.first, kind: "processing",
      amount_cents: 69, estimated: false, provider_reference: "txn_pf_#{SecureRandom.hex(4)}")
    create(:stripe_fee_evidence, :verified, payment: payment, fee_component: component,
      provider_balance_transaction_id: component.provider_reference)
    counts = -> { [AuditLog.count, Settlement.count, Payout.count, PayoutCustodyDetermination.count] }
    before = counts.call

    output = run_task
    expect(counts.call).to eq(before)
    expect(lines(output, "guards").sole).to include("payouts_require_custody" => "true", "reader_rule_current" => "true")
    expect(lines(output, "undisposed").sole).to include("gate_zero_undisposed" => "PASS")
    expect(lines(output, "custody").sole).to include("undetermined_paid_payouts" => "0")
    expect(lines(output, "event").sole).to include("event_id" => event.id.to_s, "needs_finalizing" => "yes",
      "reserved_cents" => "3000", "sent_cents" => "0", "latest_reader" => "nfc-a2")
    rows = lines(output, "payout").index_by { |row| row["payout_id"] }
    expect(rows.fetch(sent.id.to_s)).to include("current" => "false", "submitted" => "true",
      "restated_at" => payment.reload.capture_recorded_at.utc.iso8601(6))
    expect(rows.fetch(sent.id.to_s)["action"]).to start_with("record paid only with transfer evidence before")
    expect(rows.fetch(pending.id.to_s)).to include("submitted" => "false", "action" => "not sent: fail and reissue on a new version")
  end

  # CodeRabbit 4703321691: a disabled trigger keeps its pg_trigger row.
  # CodeRabbit 4704013181 (runbook step 8): a never-sent payout on a version
  # without the capture's $0 line defeats the P4 proof of an open
  # over-return, so finalizing first is refused. Finance confirms no transfer
  # left, fails the reservation, reruns preflight, then finalizes and
  # reissues on the new version.
  it "clears a stale never-sent reservation before re-finalizing when it blocks the proof" do
    allow(EmailService).to receive(:send_refund_notification_async)
    allow(StripeService).to receive(:verify_payment_context!)
    record_card_sale!(event, ticket_type: ticket_type, quantity: 5, processing_fee_cents: 100)
    stale = PayoutCreator.call(settlement: Settlements::Finalizer.call(event: event, actor: admin), actor: admin,
      idempotency_key: "pf-stale", amount_cents: 1000)
    expect(stale.reload).to have_attributes(status: "processing", provider_payout_id: "manual_po_#{stale.id}")
    order, payment, capture = classified_capture(items: [[1200, 160, 0, 0]], event: event)
    component = create(:fee_component, order: order, order_item: order.order_items.first, kind: "processing",
      amount_cents: 69, estimated: false, provider_reference: "txn_pfs_#{SecureRandom.hex(4)}")
    create(:stripe_fee_evidence, :verified, payment: payment, fee_component: component,
      provider_balance_transaction_id: component.provider_reference)
    ingest_provider_refund!(payment, 1360, id: "re_pfs_#{SecureRandom.hex(3)}")
    lose_dispute!(payment, "dp_pfs_#{SecureRandom.hex(3)}", amount: 1360)
    Commerce::NeverFulfilledResolution.evaluate!(capture.reload, trigger: "spec")
    expect(ReconciliationException.open.where(payment: payment, code: "never_fulfilled_buyer_overpaid")).to exist

    output = run_task
    expect(lines(output, "event").sole).to include("needs_finalizing" => "yes")
    # Submitted (a manual placeholder) before the restatement: only the bank
    # can say whether it left.
    expect(lines(output, "payout").sole).to include("payout_id" => stale.id.to_s, "submitted" => "true",
      "action" => a_string_ending_with("else fail and reissue"))
    expect(Commerce::NeverFulfilledPayoutHold.blocked?(event)).to be(true)
    expect { Settlements::Finalizer.call(event: event, actor: admin) }
      .to raise_error(Settlements::Finalizer::FinalizationError, /Resolve open reconciliation exceptions/)

    # The bank confirms nothing left: the reservation fails (no return
    # evidence, since no money moved).
    PayoutReconciler.call(payout: stale, actor: admin, status: "failed", provider_payout_id: stale.provider_payout_id,
      evidence: { reference: "Bank shows no transfer", reason: "Never sent to the bank",
        confirmed_at: Time.current.utc.iso8601(6) })
    expect(stale.reload).to be_status_failed
    expect(Commerce::NeverFulfilledPayoutHold.blocked?(event)).to be(false)
    rerun = run_task
    expect(lines(rerun, "payout")).to be_empty
    expect(lines(rerun, "event").sole).to include("needs_finalizing" => "yes", "reserved_cents" => "0")

    reissued = PayoutCreator.call(settlement: Settlements::Finalizer.call(event: event, actor: admin), actor: admin,
      idempotency_key: "pf-reissue", amount_cents: 1000)
    expect(reissued.reload).to be_status_processing
    expect(lines(run_task, "event").sole).to include("needs_finalizing" => "no")
  end

  it "fails the guard gate when a required trigger exists but is disabled" do
    ActiveRecord::Base.connection.execute("INSERT INTO financial_cutovers (key) VALUES " \
      "('#{FinancialIntegrity::PAYOUT_ENTRY_CUTOVER}') ON CONFLICT (key) DO NOTHING")
    expect(lines(run_task, "guards").sole).to include("payouts_require_custody" => "true", "gate_guards" => "PASS")
    ActiveRecord::Base.connection.execute("ALTER TABLE payouts DISABLE TRIGGER payouts_require_custody")
    expect(lines(run_task, "guards").sole).to include("payouts_require_custody" => "false", "gate_guards" => "FAIL")
  end

  # CodeRabbit 4703321693: the task reads one repeatable-read snapshot. Every
  # statement commits on its own here, as on production, and another session
  # classifies and commits a capture after the statement was computed.
  describe "snapshot", :non_transactional do
    self.use_transactional_tests = false

    def clean!
      raise "Isolated test database required" unless ActiveRecord::Base.connection_db_config.database.end_with?("_test")

      ActiveRecord::Base.connection.execute(<<~SQL)
        TRUNCATE TABLE audit_logs, audit_write_failures, organizations, users, organizer_profiles, events, site_settings,
          webhook_events, checkout_attempts
        RESTART IDENTITY CASCADE
      SQL
    end

    # The outer setup commits here too, so everything is removed afterwards.
    after { clean! }

    it "counts only what its own snapshot saw when a capture is classified mid-run" do
      record_card_sale!(event, ticket_type: ticket_type, quantity: 2)
      classified_capture(items: [[1200, 160, 0, 0]], event: event)
      interleaved = false
      allow(Settlements::Calculator).to receive(:call).and_wrap_original do |original, *args|
        result = original.call(*args)
        unless interleaved
          interleaved = true
          Thread.new do
            ActiveRecord::Base.connection_pool.with_connection { classified_capture(items: [[500, 0, 0, 0]], event: event) }
          end.join
        end
        result
      end

      output = run_task
      expect(interleaved).to be(true)
      expect(UnfulfilledCapture.joins(:order).where(orders: { event_id: event.id }).count).to eq(2)
      expect(lines(output, "snapshot").sole).to include("isolation" => "repeatable_read", "read_only" => "on")
      expect(lines(output, "event").sole).to include("classified_captures" => "1")
    end
  end
end
