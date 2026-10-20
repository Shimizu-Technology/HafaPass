# frozen_string_literal: true

require "rails_helper"
require Rails.root.join("db/migrate/20261020120000_adopt_all_in_buyer_fee_defaults")

# Who bears actual card processing is snapshotted on each order. NULL is a
# legacy order (organizer bears it); "platform" orders leave organizer
# proceeds whole and HåfaPass absorbs the cost out of its fee.
RSpec.describe "Settlement processing-fee bearer" do
  let(:profile) { create(:organizer_profile, :verified) }
  let(:organization) { profile.organization }
  let(:actor) { profile.user }
  let(:event) { create(:event, :completed, organizer_profile: profile) }

  # Mirrors a settled card order: platform fee 5% + $1.00 on a $50.00 ticket
  # (350), split between buyer and organizer by policy, plus Stripe's actual
  # verified processing cost.
  def record_sale!(sale_event, bearer:, subtotal_cents: 5000, buyer_fee_cents: 350, organizer_fee_cents: 0,
    processing_fee_cents: 185)
    total = subtotal_cents + buyer_fee_cents
    order = create(:order, event: sale_event, subtotal_cents: subtotal_cents, service_fee_cents: buyer_fee_cents,
      organizer_fee_cents: organizer_fee_cents, discount_cents: 0, total_cents: total,
      processing_fee_bearer_snapshot: bearer)
    item = create(:order_item, order: order, unit_price_cents: subtotal_cents, subtotal_cents: subtotal_cents,
      fee_cents: buyer_fee_cents, organizer_fee_cents: organizer_fee_cents,
      organizer_proceeds_cents: subtotal_cents - organizer_fee_cents)
    create(:fee_component, order: order, kind: "platform", amount_cents: buyer_fee_cents + organizer_fee_cents,
      estimated: true)
    component = create(:fee_component, order: order, order_item: item, kind: "processing",
      amount_cents: processing_fee_cents, estimated: false, provider_reference: "txn_fixture_#{SecureRandom.hex(8)}")
    capture = create(:payment, :succeeded, order: order, amount_cents: total)
    create(:stripe_fee_evidence, :verified, payment: capture, fee_component: component,
      provider_balance_transaction_id: component.provider_reference)
    [order, item, component]
  end

  def canonical(items)
    items.map { |item| item.slice(:kind, :amount_cents, :currency, :source_type, :source_id, :description, :metadata) }
  end

  describe "legacy statements" do
    let(:migration) { AdoptAllInBuyerFeeDefaults.new }

    after { SiteSetting.reset_column_information }

    it "keeps an existing finalized statement's digest, totals and payout eligibility after the migration" do
      _, _, component = record_sale!(event, bearer: nil, buyer_fee_cents: 250, processing_fee_cents: 183)
      create(:connected_account, organization: organization)
      SiteSetting.instance
      ActiveRecord::Migration.suppress_messages { migration.down }
      SiteSetting.reset_column_information
      SiteSetting.instance.update_columns(service_fee_percent: 3.0, service_fee_flat_cents: 50)
      settlement = Settlements::Finalizer.call(event: event, actor: actor)
      before = settlement.reload.attributes.slice(*Settlement::MONEY_COLUMNS.map(&:to_s) - ["platform_processing_fee_cents"],
        "source_digest", "version")
      stored_items = settlement.settlement_items.order(:id).map { |item| item.attributes.except("id", "settlement_id", "created_at", "updated_at") }

      ActiveRecord::Migration.suppress_messages { migration.up }
      SiteSetting.reset_column_information
      expect(SiteSetting.instance.reload).to have_attributes(service_fee_percent: 5.0, service_fee_flat_cents: 100,
        processing_fee_bearer: "platform")

      result = Settlements::Calculator.call(event)
      processing = result.items.find { |item| item[:kind] == "processing_fee" }
      expect(processing.slice(:amount_cents, :description, :metadata)).to eq(amount_cents: -183,
        description: "Actual payment processing cost",
        metadata: { order_id: component.order_id, provider_reference: component.provider_reference })
      expect(result.attributes[:source_digest]).to eq(before["source_digest"])
      expect(result.attributes.slice(:payable_cents, :processing_fee_cents, :platform_processing_fee_cents))
        .to eq(payable_cents: 4817, processing_fee_cents: 183, platform_processing_fee_cents: 0)

      settlement.reload
      expect(settlement.attributes.slice(*before.keys)).to eq(before)
      expect(settlement.platform_processing_fee_cents).to eq(0)
      expect(settlement.settlement_items.order(:id).map { |item| item.attributes.except("id", "settlement_id", "created_at", "updated_at") })
        .to eq(stored_items)
      expect(Settlements::Finalizer.call(event: event, actor: actor)).to eq(settlement)
      expect(OrganizationPayoutBalance.available_cents(organization)).to eq(4817)
      payout = PayoutCreator.call(settlement: settlement, actor: actor, idempotency_key: "legacy-after-migration")
      expect(payout).to have_attributes(status: "paid", amount_cents: 4817)
    end

    it "never reads the live bearer setting for an existing order" do
      record_sale!(event, bearer: nil, processing_fee_cents: 183)
      digest = Settlements::Calculator.call(event).attributes[:source_digest]

      %w[platform organizer].each do |bearer|
        SiteSetting.instance.update!(processing_fee_bearer: bearer, service_fee_percent: 9, service_fee_flat_cents: 0)
        attributes = Settlements::Calculator.call(event).attributes
        expect(attributes[:source_digest]).to eq(digest)
        expect(attributes).to include(processing_fee_cents: 183, platform_processing_fee_cents: 0, payable_cents: 4817)
      end
    end
  end

  it "pays the organizer the full ticket price when the buyer pays an all-in fee" do
    _, _, component = record_sale!(event, bearer: "platform")

    settlement = Settlements::Finalizer.call(event: event, actor: actor)

    expect(settlement).to have_attributes(gross_cents: 5000, net_cents: 5350, platform_fee_cents: 350,
      processing_fee_cents: 0, platform_processing_fee_cents: 185, organizer_proceeds_cents: 5000,
      payable_cents: 5000, negative_balance_cents: 0, net_platform_fee_cents: 165)
    item = settlement.settlement_items.find_by!(kind: "processing_fee")
    expect(item).to have_attributes(amount_cents: 0, description: "Card processing covered by HåfaPass",
      source_type: "FeeComponent", source_id: component.id)
    expect(item.metadata).to include("processing_fee_bearer" => "platform", "platform_cost_cents" => 185)
    expect(AuditLog.find_by!(auditable: settlement, action: "settlement.finalized").after_data)
      .to include("platform_processing_fee_cents" => 185, "processing_fee_cents" => 0)
    expect(OrganizationPayoutBalance.available_cents(organization)).to eq(5000)
  end

  it "binds a later actual processing cost into the digest without changing organizer proceeds" do
    order = create(:order, event: event, subtotal_cents: 5000, service_fee_cents: 350, total_cents: 5350,
      processing_fee_bearer_snapshot: "platform")
    create(:order_item, order: order, unit_price_cents: 5000, subtotal_cents: 5000, fee_cents: 350,
      organizer_proceeds_cents: 5000)
    before = Settlements::Calculator.call(event).attributes

    create(:fee_component, order: order, kind: "processing", amount_cents: 185, estimated: false,
      provider_reference: "txn_late")
    after = Settlements::Calculator.call(event).attributes

    expect(after[:source_digest]).not_to eq(before[:source_digest])
    expect(after[:payable_cents]).to eq(before[:payable_cents])
    expect(after[:platform_processing_fee_cents]).to eq(185)
  end

  {
    "buyer pays" => { buyer_fee_cents: 350, organizer_fee_cents: 0, proceeds: 5000 },
    "organizer absorbs" => { buyer_fee_cents: 0, organizer_fee_cents: 350, proceeds: 4650 },
    "split 50/50" => { buyer_fee_cents: 175, organizer_fee_cents: 175, proceeds: 4825 }
  }.each do |policy, fees|
    it "settles a #{policy} order under each bearer" do
      expectations = {
        "platform" => { processing_fee_cents: 0, platform_processing_fee_cents: 185, payable_cents: fees[:proceeds] },
        "organizer" => { processing_fee_cents: 185, platform_processing_fee_cents: 0, payable_cents: fees[:proceeds] - 185 },
        nil => { processing_fee_cents: 185, platform_processing_fee_cents: 0, payable_cents: fees[:proceeds] - 185 }
      }
      expectations.each do |bearer, expected|
        bearer_event = create(:event, :completed, organizer_profile: profile)
        record_sale!(bearer_event, bearer: bearer, buyer_fee_cents: fees[:buyer_fee_cents],
          organizer_fee_cents: fees[:organizer_fee_cents])

        attributes = Settlements::Calculator.call(bearer_event).attributes
        expect(attributes).to include(organizer_proceeds_cents: fees[:proceeds], platform_fee_cents: 350, **expected)
      end
    end
  end

  it "computes buyer, absorb and split fees from the creation-time settings and snapshots the bearer" do
    SiteSetting.instance.update!(service_fee_percent: 5.0, service_fee_flat_cents: 100, processing_fee_bearer: "platform")
    results = { buyer_pays: 100, organizer_absorbs: 0, split_fees: 50 }.to_h do |policy, buyer_percent|
      sale_event = create(:event, :published, organizer_profile: profile, fee_policy: policy, buyer_fee_percent: buyer_percent)
      type = create(:ticket_type, event: sale_event, price_cents: 2500, quantity_available: 10)
      order = Commerce::OrderCreator.call(event: sale_event, line_items: [{ ticket_type_id: type.id, quantity: 2 }],
        buyer_email: "buyer@example.com", buyer_name: "Buyer", payment_required: false).order
      [policy, order.reload]
    end

    # 5% of $50.00 + 2 × $1.00 = $4.50 platform fee on each order.
    expect(results.transform_values { |order| [order.service_fee_cents, order.organizer_fee_cents] })
      .to eq(buyer_pays: [450, 0], organizer_absorbs: [0, 450], split_fees: [225, 225])
    expect(results.values.map(&:processing_fee_bearer_snapshot).uniq).to eq(["platform"])
    expect(results[:buyer_pays].fee_components.find_by!(kind: "platform").metadata)
      .to include("percent" => "5.0", "flat_cents_per_ticket" => 100, "processing_fee_bearer" => "platform")
    expect(results[:buyer_pays].order_items.sum(:organizer_proceeds_cents)).to eq(5000)

    SiteSetting.instance.update!(processing_fee_bearer: "organizer")
    order = results[:buyer_pays]
    create(:fee_component, order: order, kind: "processing", amount_cents: 175, estimated: false, provider_reference: "txn_x")
    expect(Settlements::Calculator.call(order.event).attributes)
      .to include(payable_cents: 5000, processing_fee_cents: 0, platform_processing_fee_cents: 175)
    expect { order.update!(processing_fee_bearer_snapshot: "organizer") }.to raise_error(ActiveRecord::ReadonlyAttributeError)
  end

  it "charges no fee on free tickets and records the organizer bearer when configured" do
    SiteSetting.instance.update!(processing_fee_bearer: "organizer")
    free_event = create(:event, :published, organizer_profile: profile)
    type = create(:ticket_type, event: free_event, price_cents: 0, quantity_available: 10)

    order = Commerce::OrderCreator.call(event: free_event, line_items: [{ ticket_type_id: type.id, quantity: 2 }],
      buyer_email: "buyer@example.com", buyer_name: "Buyer", payment_required: false).order

    expect(order.reload).to have_attributes(service_fee_cents: 0, organizer_fee_cents: 0, total_cents: 0,
      processing_fee_bearer_snapshot: "organizer")
  end

  it "keeps refunds, lost disputes and negative balance carry-forward correct for platform-bearer orders" do
    order, item, = record_sale!(event, bearer: "platform")
    create(:connected_account, organization: organization)
    settlement = Settlements::Finalizer.call(event: event, actor: actor)
    payout = PayoutCreator.call(settlement: settlement, actor: actor, idempotency_key: "platform-paid")
    expect(payout.amount_cents).to eq(5000)

    refund = create(:refund, order: order, payment: order.payments.first, amount_cents: 1070)
    create(:refund_item, refund: refund, order_item: item, amount_cents: 1070, organizer_proceeds_cents: 1000,
      fee_cents: 70)
    order.update!(status: :partially_refunded, refund_amount_cents: 1070)
    refunded = Settlements::Finalizer.call(event: event, actor: actor)
    # The organizer returns only the refunded ticket price; the platform keeps
    # covering the original capture cost, which Stripe does not return.
    expect(refunded).to have_attributes(organizer_proceeds_cents: 4000, platform_fee_cents: 280,
      processing_fee_cents: 0, platform_processing_fee_cents: 185, payable_cents: 4000, negative_balance_cents: 1000)

    Dispute.create!(order: order, payment: order.payments.first, provider: "stripe", provider_dispute_id: "dp-platform",
      amount_cents: 500, currency: "usd", status: :lost, opened_at: Time.current, closed_at: Time.current)
    disputed = Settlements::Finalizer.call(event: event, actor: actor)
    expect(disputed).to have_attributes(payable_cents: 3500, negative_balance_cents: 1500, adjustment_cents: -500)

    second_event = create(:event, :completed, organizer_profile: profile)
    record_sale!(second_event, bearer: "platform")
    second = Settlements::Finalizer.call(event: second_event, actor: actor)
    expect(second.payable_cents).to eq(5000)
    expect(OrganizationPayoutBalance.available_cents(organization)).to eq(3500)
    expect do
      PayoutCreator.call(settlement: second, actor: actor, idempotency_key: "overdraw", amount_cents: 5000)
    end.to raise_error(PayoutCreator::PayoutError, /available balance/)
  end

  it "never charges the organizer when processing exceeds the platform fee" do
    # An admin-set zero fee and a fully refunded order both leave the platform
    # with less fee revenue than the actual capture cost.
    record_sale!(event, bearer: "platform", buyer_fee_cents: 0, processing_fee_cents: 175)
    attributes = Settlements::Calculator.call(event).attributes
    expect(attributes).to include(platform_fee_cents: 0, processing_fee_cents: 0, platform_processing_fee_cents: 175,
      organizer_proceeds_cents: 5000, payable_cents: 5000, negative_balance_cents: 0)
    expect(Settlement.new(attributes.slice(:platform_fee_cents, :platform_processing_fee_cents)).net_platform_fee_cents)
      .to eq(-175)

    refund_event = create(:event, :completed, organizer_profile: profile)
    order, item, = record_sale!(refund_event, bearer: "platform")
    refund = create(:refund, order: order, payment: order.payments.first, amount_cents: 5350)
    create(:refund_item, refund: refund, order_item: item, amount_cents: 5350, organizer_proceeds_cents: 5000, fee_cents: 350)
    order.update!(status: :refunded, refund_amount_cents: 5350)

    settlement = Settlements::Finalizer.call(event: refund_event, actor: actor)
    expect(settlement).to have_attributes(platform_fee_cents: 0, processing_fee_cents: 0, platform_processing_fee_cents: 185,
      organizer_proceeds_cents: 0, payable_cents: 0, negative_balance_cents: 0, net_platform_fee_cents: -185)
  end
end
