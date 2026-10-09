require "rails_helper"

RSpec.describe StripeProcessingFees do
  let(:event) { create(:event, :completed) }
  let(:order) { create(:order, event: event, total_cents: 1080, subtotal_cents: 1000, service_fee_cents: 80) }
  let(:payment) { create(:payment, :succeeded, order: order, amount_cents: 1080, provider_payment_id: "pi_fees") }
  let(:balance) do
    { "id" => "txn_charge_fee", "source" => "ch_paid", "type" => "charge", "status" => "pending",
      "amount" => 1080, "currency" => "usd", "fee" => 61, "net" => 1019,
      "fee_details" => [{ "type" => "stripe_fee", "amount" => 61, "currency" => "usd" }] }
  end
  let(:charge) do
    { "id" => "ch_paid", "payment_intent" => "pi_fees", "status" => "succeeded", "paid" => true,
      "captured" => true, "amount" => 1080, "amount_captured" => 1080, "currency" => "usd", "livemode" => false,
      "balance_transaction" => balance }
  end
  let(:intent) do
    { "id" => "pi_fees", "status" => "succeeded", "amount" => 1080, "amount_received" => 1080,
      "currency" => "usd", "livemode" => false, "latest_charge" => charge }
  end

  before do
    allow(StripeService).to receive(:retrieve_fee_payment_intent).with(payment).and_return(intent)
    create(:order_item, order: order, unit_price_cents: 1000, quantity: 1, subtotal_cents: 1000, fee_cents: 80, organizer_proceeds_cents: 1000)
  end

  def reconcile
    described_class.call(payment: payment)
  end

  it "records one actual cost and exact source identities; repeated and later available snapshots do not duplicate it" do
    first = reconcile
    expect(first).to be_status_verified
    expect(first).to have_attributes(provider_charge_id: "ch_paid", provider_balance_transaction_id: "txn_charge_fee",
      amount_cents: 1080, fee_cents: 61, net_cents: 1019, currency: "usd", balance_status: "pending")
    expect(first.fee_component).to have_attributes(amount_cents: 61, estimated: false, provider_reference: "txn_charge_fee")
    expect(first.fee_component.metadata).to include("payment_id" => payment.id)
    balance["status"] = "available"
    expect { reconcile }.not_to change(FeeComponent, :count)
    expect(first.reload.balance_status).to eq("available")
    expect(Settlements::Calculator.call(event).attributes[:processing_fee_cents]).to eq(61)
    expect(described_class.missing_count(event.orders.select(:id))).to eq(0)
  end

  it "blocks finance even when no fee job or exception row exists" do
    payment
    expect(described_class.missing_count(event.orders.select(:id))).to eq(1)
    expect(OrganizationPayoutBalance.available_cents(event.organization)).to eq(0)
    expect { Settlements::Finalizer.call(event: event, actor: event.organizer_profile.user) }
      .to raise_error(Settlements::Finalizer::FinalizationError, /actual Stripe processing fees/)
    reconcile
    expect(Settlements::Finalizer.call(event: event, actor: event.organizer_profile.user).processing_fee_cents).to eq(61)
  end

  it "durably retries an unavailable asynchronous balance transaction and closes only its pending exception after recovery" do
    charge["balance_transaction"] = nil
    expect { reconcile }.to raise_error(described_class::RetryableError)
    evidence = payment.reload.stripe_fee_evidence
    expect(evidence).to be_status_pending
    expect(evidence.next_attempt_at).to be_future
    expect(payment.reconciliation_exceptions.open).to exist(code: described_class::PENDING_CODE)
    expect(FeeComponent.where(kind: "processing")).to be_empty
    charge["balance_transaction"] = balance
    reconcile
    expect(evidence.reload).to be_status_verified
    expect(payment.reconciliation_exceptions.open).not_to exist(code: described_class::PENDING_CODE)
  end

  it "retains a financial hold through network failure and recovers without inventing a fee" do
    allow(StripeService).to receive(:retrieve_fee_payment_intent).and_raise(Stripe::APIConnectionError, "lost")
    expect { reconcile }.to raise_error(described_class::RetryableError)
    expect(payment.reload.stripe_fee_evidence).to be_status_pending
    expect(described_class.missing_count(event.orders.select(:id))).to eq(1)
    expect(FeeComponent.where(kind: "processing")).to be_empty
  end

  { "source" => "ch_foreign", "currency" => "eur", "amount" => 1081, "net" => 1020,
    "type" => "transfer" }.each do |field, incorrect|
    it "quarantines a foreign or contradictory balance #{field}" do
      balance[field] = incorrect
      expect(reconcile).to be_status_review_required
      expect(FeeComponent.where(kind: "processing")).to be_empty
      expect(payment.reconciliation_exceptions.open).to exist(code: described_class::REVIEW_CODE)
    end
  end

  it "quarantines an unrelated charge" do
    charge["payment_intent"] = "pi_another_order"
    expect(reconcile).to be_status_review_required
    expect(FeeComponent.where(kind: "processing")).to be_empty
  end

  it "rejects a live provider snapshot for the original sandbox payment" do
    intent["livemode"] = true
    expect(reconcile).to be_status_review_required
    expect(FeeComponent.where(kind: "processing")).to be_empty
  end

  it "holds mixed application fees and absent IC+ breakdowns for approved accounting review" do
    balance["fee_details"][0]["type"] = "application_fee"
    expect(reconcile).to be_status_review_required
    expect(FeeComponent.where(kind: "processing")).to be_empty
    balance["fee_details"] = []
    expect(reconcile).to be_status_review_required
  end

  it "preserves the immutable original ledger and blocks cash release on a contradictory later snapshot" do
    evidence = reconcile
    balance["fee"] = 65
    balance["net"] = 1015
    balance["fee_details"][0]["amount"] = 65
    expect { reconcile }.not_to change(FeeComponent, :count)
    expect(evidence.reload).to be_status_review_required
    expect(evidence.fee_component.amount_cents).to eq(61)
    expect(OrganizationPayoutBalance.available_cents(event.organization)).to eq(0)
  end

  it "does not guess a mapping for existing manually entered processing costs" do
    create(:fee_component, order: order, kind: "processing", amount_cents: 61, estimated: false)
    expect(reconcile).to be_status_review_required
    expect(FeeComponent.where(kind: "processing").count).to eq(1)
  end

  it "excludes simulated and cash captures from provider proof and does not call Stripe" do
    payment.update!(provider_payment_id: "sim_pi_fixture")
    expect(reconcile).to be_nil
    expect(described_class.missing_count(event.orders.select(:id))).to eq(0)
    expect(StripeService).not_to have_received(:retrieve_fee_payment_intent)
  end

  it "keeps refund/dispute fee adjustments separate and requires evidence before closing their hold" do
    reconcile
    2.times { described_class.require_adjustment_review!(payment, reference: "refund:re_exact") }
    exception = payment.reconciliation_exceptions.open.find_by!(code: "stripe_fee_adjustment_review_required")
    expect(payment.reconciliation_exceptions.count).to eq(1)
    expect(OrganizationPayoutBalance.available_cents(event.organization)).to eq(0)
    expect(payment.stripe_fee_evidence.fee_component.amount_cents).to eq(61)
    exception.resolve!
    described_class.require_adjustment_review!(payment, reference: "refund:re_exact")
    expect(payment.reconciliation_exceptions.open).to be_empty
  end
end
