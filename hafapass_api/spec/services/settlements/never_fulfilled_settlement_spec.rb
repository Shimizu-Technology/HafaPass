# frozen_string_literal: true

require "rails_helper"
require "ostruct"

# A1-R1 review finding 2 (docs/design/never-fulfilled-captures.md §6.7): an
# order HåfaPass never fulfilled is not a sale. A capture returned partly by
# refund and partly by lost dispute pays the organizer nothing, whatever the
# order's status. Checked on the real calculator, finalizer and payout
# reservation in an event that also has an ordinary sale, and for proven
# platform-only overpayment (P4), which must not hold the organizer.
RSpec.describe "Never-fulfilled capture settlement" do
  include ActiveJob::TestHelper

  let(:admin) { create(:user, :admin) }
  let(:profile) { create(:organizer_profile, :verified) }
  let(:organization) { profile.organization }
  let(:event) { create(:event, :completed, organization: organization, organizer_profile: profile) }

  before do
    allow(StripeService).to receive(:verify_payment_context!)
    allow(EmailService).to receive(:send_refund_notification_async)
    allow(StripeProcessingFees).to receive(:require_adjustment_review!)
    allow(Sentry).to receive(:capture_message)
    allow(PayoutGateway).to receive(:submit) do |payout|
      PayoutGateway::Result.new(provider_payout_id: "manual_po_#{payout.id}", status: :processing)
    end
  end

  # An ordinary $100.00 sale (5 × $20.00, buyer fees $5.00, processing $1.00).
  def ordinary_sale!
    record_card_sale!(event, ticket_type: create(:ticket_type, event: event, price_cents: 2000), quantity: 5,
      processing_fee_cents: 100)
  end

  # The review's $13.60 order: no tickets, $12.00 proceeds + $1.60 fee, with
  # its verified actual processing ($0.69, borne by HåfaPass).
  def never_fulfilled_capture!
    order, payment, capture = classified_capture(items: [[1200, 160, 0, 0]], event: event)
    component = create(:fee_component, order: order, order_item: order.order_items.first, kind: "processing",
      amount_cents: 69, estimated: false, provider_reference: "txn_f2_#{SecureRandom.hex(4)}")
    create(:stripe_fee_evidence, :verified, payment: payment, fee_component: component,
      provider_balance_transaction_id: component.provider_reference)
    issue = ReconciliationException.create!(order: order, payment: payment, code: "late_payment_success_after_hold_expiry")
    [order, payment, capture, issue]
  end

  def statement(event)
    Settlements::Calculator.call(event).attributes.slice(:gross_cents, :refund_cents, :organizer_proceeds_cents,
      :platform_fee_cents, :processing_fee_cents, :adjustment_cents, :payable_cents)
  end

  it "pays the organizer nothing for a $5 refund plus an $8.60 loss, and exactly the ordinary sale's payable" do
    ordinary_sale!
    approved_bank_account!(organization, actor: profile.user, admin: admin)
    sale_only = statement(event)
    expect(sale_only[:payable_cents]).to eq(9900)

    order, payment, capture, issue = never_fulfilled_capture!
    ingest_provider_refund!(payment, 500, id: "re_f2_five")
    lose_dispute!(payment, "dp_f2_rest", amount: 860)

    expect(order.reload).to have_attributes(status: "partially_refunded", never_fulfilled_at: capture.created_at)
    expect(ledger(capture)).to have_attributes(owed_cents: 0, excess_cents: 0)
    expect(issue.reload).to be_resolved
    # Before the fix the order's $12.00 proceeds minus the refund's share
    # ($7.59) were payable on top of the sale. Its processing is HåfaPass's
    # (snapshot bearer "platform"), a platform cost outside every organizer
    # figure (A2), so nothing else changes.
    expect(statement(event)).to eq(sale_only)
    expect(Settlements::Calculator.call(event).attributes[:platform_processing_fee_cents]).to eq(0)
    expect(Commerce::NeverFulfilledPayoutHold.blocked?(event)).to be(false)

    # The 7bcd97c2 reader disagrees after a rollback: it counts the order's
    # $7.58 proceeds and debits the organizer the $8.60 loss and $0.69
    # processing ($97.29). So the database lets only this reader finalize
    # or create a payout on this event (the fence across the A1/A2 gap).
    expect(Legacy7bcd97c2.settlements_calculator.call(event).attributes[:payable_cents]).to eq(9729)
    expect do
      ActiveRecord::Base.transaction(requires_new: true) { Legacy7bcd97c2.settlements_finalizer.call(event: event, actor: admin) }
    end.to raise_error(ActiveRecord::StatementInvalid, /never-fulfilled settlement reader/)

    settlement = Settlements::Finalizer.call(event: event, actor: admin)
    expect(settlement).to have_attributes(payable_cents: 9900, status: "finalized")
    expect do
      ActiveRecord::Base.transaction(requires_new: true) do
        create(:payout, organization: organization, event: event, settlement: settlement, amount_cents: 10_658)
      end
    end.to raise_error(ActiveRecord::StatementInvalid, /never-fulfilled settlement reader/)
    payout = PayoutCreator.call(settlement: settlement, actor: admin, idempotency_key: "f2-payout")
    expect(payout).to have_attributes(amount_cents: 9900, status: "processing")
  end

  it "keeps a proven platform-only overpayment (P4) from holding the organizer or changing the payable" do
    ordinary_sale!
    approved_bank_account!(organization, actor: profile.user, admin: admin)
    _order, payment, capture, = never_fulfilled_capture!
    ingest_provider_refund!(payment, 1360, id: "re_f2_full")
    lose_dispute!(payment, "dp_f2_twice", amount: 1360)
    Commerce::NeverFulfilledResolution.evaluate!(capture.reload, trigger: "spec")

    overpaid = ReconciliationException.open.where(payment: payment, code: Commerce::NeverFulfilledResolution::OVERPAID_CODE)
    expect(overpaid.sole).to have_attributes(actual_amount_cents: 1360)
    expect(overpaid.sole.details).to include("platform_only" => true)
    expect(ledger(capture)).to have_attributes(owed_cents: 0, excess_cents: 1360)
    expect(Commerce::NeverFulfilledPayoutHold.blocked?(event)).to be(false)

    settlement = Settlements::Finalizer.call(event: event, actor: admin)
    expect(settlement).to have_attributes(payable_cents: 9900)
    payout = PayoutCreator.call(settlement: settlement, actor: admin, idempotency_key: "f2-p4-payout")
    expect(payout).to have_attributes(amount_cents: 9900, status: "processing")
    expect(overpaid.sole.reload).to be_open
  end

  it "holds finalization and payouts in the database while a never-fulfilled item is open" do
    ordinary_sale!
    approved_bank_account!(organization, actor: profile.user, admin: admin)
    never_fulfilled_capture!

    expect { Settlements::Finalizer.call(event: event, actor: admin) }.to raise_error(Settlements::Finalizer::FinalizationError)
    expect do
      ActiveRecord::Base.transaction(requires_new: true) do
        Settlement.new(event: event, organization: organization, status: :finalized, version: 1, source_digest: "f2",
          calculated_at: Time.current, finalized_at: Time.current, currency: "usd").save!(validate: false)
      end
    end.to raise_error(ActiveRecord::StatementInvalid, /Repayment fence/)
  end
end
