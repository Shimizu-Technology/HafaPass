# frozen_string_literal: true

require "rails_helper"
require "rake"

# Read-only release evidence (docs/design/never-fulfilled-captures.md §10.5,
# script/never_fulfilled/release_evidence.sql).
RSpec.describe "never_fulfilled:release_evidence" do
  before(:all) do
    Rails.application.load_tasks unless Rake::Task.task_defined?("never_fulfilled:release_evidence")
  end

  let(:task) { Rake::Task["never_fulfilled:release_evidence"] }
  let(:sha) { "a" * 40 }

  def run_task(env)
    task.reenable
    original = env.keys.index_with { |key| ENV.fetch(key, nil) }
    env.each { |key, value| ENV[key] = value }
    captured = StringIO.new
    $stdout = captured
    task.invoke
    captured.string
  ensure
    $stdout = STDOUT
    original&.each { |key, value| ENV[key] = value }
  end

  it "reports a legacy refund past the gate as not adjudicable inside the in-flight bound, and writes nothing" do
    order, payment, = classified_capture(items: [[1200, 160, 0, 0]])
    ReconciliationException.create!(order: order, payment: payment, code: "late_payment_success_after_hold_expiry")
    refund = before_repayment_fence do
      payment.refunds.create!(order: order, provider: "stripe", idempotency_key: "late-capture:payment:#{payment.id}",
        amount_cents: payment.amount_cents, currency: "usd", status: :pending, failure_code: "provider_result_unknown")
    end
    counts = -> { [AuditLog.count, Refund.count, RepaymentOperation.count, ReconciliationException.count] }
    before = counts.call

    output = run_task("R1_SHA" => sha, "R1_LIVE_AT" => 1.hour.ago.utc.iso8601)

    line = output.lines.find { |text| text.start_with?("section=legacy_refunds_on_fenced_payments") }
    expect(line).to include("refund_id=#{refund.id}", "failure_code=provider_result_unknown", "adjudicable=false")
    expect(output).to include("section=triggers\ttgname=refunds_repayment_fence", "section=triggers\ttgname=payouts_repayment_fence")
    expect(output).to match(/section=never_fulfilled_items\tcode=late_payment_success_after_hold_expiry\tstatus=0\titems=1/)
    expect(counts.call).to eq(before)

    # The submission's bound alone is not enough: an older release can still
    # resend inside its 23-hour replay window (A1-R1 review finding 4).
    refund.update_columns(updated_at: (Commerce::BuyerRepayment.in_flight_bound + 1.minute).ago)
    later = run_task("R1_SHA" => sha, "R1_LIVE_AT" => 1.hour.ago.utc.iso8601)
    expect(later.lines.find { |text| text.start_with?("section=legacy_refunds_on_fenced_payments") }).to include("adjudicable=false")

    # After created_at + the replay window + the bound, on the database clock.
    old = (Commerce::RefundCreator::PROVIDER_REPLAY_WINDOW + Commerce::BuyerRepayment.in_flight_bound + 1.minute).ago
    refund.update_columns(created_at: old, updated_at: old)
    latest = run_task("R1_SHA" => sha, "R1_LIVE_AT" => 1.hour.ago.utc.iso8601)
    expect(latest.lines.find { |text| text.start_with?("section=legacy_refunds_on_fenced_payments") }).to include("adjudicable=true")
    expect(latest).to include("section=triggers\ttgname=refunds_identity_fence", "section=triggers\ttgname=audit_logs_payout_submission_fence")
  end

  it "prints the pre-R1 baseline from 7bcd97c2 tables only" do
    output = run_task("BASELINE" => "1")
    expect(output).to include("section=refunds_provider_result_unknown")
    expect(File.read(Rails.root.join("script/never_fulfilled/baseline_before_r1.sql")))
      .not_to match(/never_fulfilled_captures|repayment_operations|financial_cutovers|hafapass_fenced_payment/)
  end
end
