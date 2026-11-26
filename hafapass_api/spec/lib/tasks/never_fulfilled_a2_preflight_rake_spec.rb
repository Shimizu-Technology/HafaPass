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
end
