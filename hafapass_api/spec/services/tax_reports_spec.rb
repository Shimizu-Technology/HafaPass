# frozen_string_literal: true

require "rails_helper"

RSpec.describe TaxReports do
  let(:organization) { create(:organization) }
  let(:profile) { create(:organizer_profile, organization: organization) }
  let(:event) { create(:event, organization: organization, organizer_profile: profile) }

  def sale(at:, environment: "live", gross: 2500, fee: 225)
    order = create(:order, :completed, event: event, completed_at: at)
    create(:order_item, order: order, unit_price_cents: gross, subtotal_cents: gross, discount_cents: 100,
      organizer_proceeds_cents: gross - 150, organizer_fee_cents: 50)
    # Captured at the sale (custody is booked no earlier than the capture).
    payment = create(:payment, :succeeded, order: order, provider_environment: environment, succeeded_at: at, created_at: at)
    # Recorded at the sale too, as a capture before its payouts is.
    stamp!(payment, :capture_recorded_at, at, trigger: "payments_capture_recorded_at") if payment.reload.capture_recorded_at
    # Completion records the fulfilling payment; a later capture is not the sale's.
    order.update!(fulfilled_by_payment_id: payment.id)
    create(:fee_component, order: order, kind: "platform", amount_cents: fee, estimated: true)
    order
  end

  def refund(order, at:, status: :succeeded)
    result = create(:refund, order: order, payment: order.payments.first, succeeded_at: at, status: status, amount_cents: 600)
    create(:refund_item, refund: result, order_item: order.order_items.first,
      amount_cents: 600, organizer_proceeds_cents: 500, fee_cents: 75, organizer_fee_cents: 25, tax_cents: 0)
    result
  end

  it "reports live collections, allocated refunds, actual processing and actually paid payouts" do
    at = Time.find_zone!("Pacific/Guam").local(2026, 10, 1)
    order = sale(at: at)
    # Recorded with the sale: processing is recognized no earlier than its
    # recording (CodeRabbit 4704932984), so a component recorded today would
    # be today's cost.
    create(:fee_component, order: order, kind: "processing", estimated: false, amount_cents: 80, created_at: at)
    create(:fee_component, order: order, kind: "processing", estimated: true, amount_cents: 999)
    %w[test simulate].each { |environment| refund(sale(at: at, environment: environment), at: at) }
    sale(at: at, environment: nil)
    later_capture = create(:payment, :succeeded, order: order, provider_environment: "live")
    # A historical later capture (recorded before A1), which reconcile's
    # backfill decides; a capture recorded since A1 and left unclassified
    # would hold this event's payouts (hafapass_unclassified_capture).
    stamp!(later_capture, :capture_recorded_at, nil, trigger: "payments_capture_recorded_at")
    refund(order, at: at + 1.day)
    refund(order, at: at + 1.day, status: :failed)
    account = create(:connected_account, organization: organization)
    settlement = create(:settlement, event: event, organization: organization)
    create(:payout, event: event, organization: organization, settlement: settlement, connected_account: account,
      amount_cents: 1700, status: :paid, paid_at: at, created_at: at - 1.year)
    create(:payout, event: event, organization: organization, settlement: settlement, connected_account: account,
      amount_cents: 999, status: :processing)
    report = described_class.new(2026)
    row = report.organizers.sole
    expect(row).to include(gross_ticket_proceeds_cents: 4800, refunds_cents: 600, fees_collected_cents: 450,
      fees_refunded_cents: 100, net_paid_cents: 1700, w9_on_file: true)
    expect(row[:tax_information]).to include("masked_tin" => "***-**-5678")
    expect(report.months[9]).to include(fees_collected_cents: 450, fees_refunded_cents: 100,
      gross_receipts_cents: 350, card_processing_costs_cents: 80)
    expect(report.as_json.to_json).not_to include("012345678")
  end

  it "uses Guam midnight and independent refund dates, including negative and refund-only years" do
    order = sale(at: Time.utc(2025, 12, 31, 13, 59))
    refund(order, at: Time.utc(2025, 12, 31, 14, 0))
    report = described_class.new(2026)
    expect(report.organizers.sole).to include(gross_ticket_proceeds_cents: 0, refunds_cents: 600, fees_collected_cents: 0)
    expect(report.months.first).to include(gross_receipts_cents: -100, fees_refunded_cents: 100)
    expect(described_class.new(2025).months.last[:gross_receipts_cents]).to eq(225)
    sale(at: Time.utc(2026, 12, 31, 14, 0))
    expect(report.months.sum { |month| month[:fees_collected_cents] }).to eq(0)
  end

  it "includes payout-only years, excludes reversed payouts and excludes payouts on test-only events" do
    sale(at: Time.utc(2025, 8, 1))
    account = create(:connected_account, organization: organization)
    settlement = create(:settlement, event: event, organization: organization)
    paid = create(:payout, event: event, organization: organization, settlement: settlement, connected_account: account,
      amount_cents: 1700, status: :paid, paid_at: Time.utc(2026, 1, 3))
    expect(described_class.new(2026).organizers.sole).to include(gross_ticket_proceeds_cents: 0, net_paid_cents: 1700)
    test_event = create(:event, organization: organization, organizer_profile: profile)
    test_order = create(:order, :completed, event: test_event, completed_at: Time.utc(2026, 1, 1))
    create(:payment, :succeeded, order: test_order, provider_environment: "test")
    create(:payout, event: test_event, organization: organization,
      settlement: create(:settlement, event: test_event, organization: organization), connected_account: account,
      amount_cents: 999, status: :paid, paid_at: Time.utc(2026, 1, 3))
    expect(described_class.new(2026).organizers.sole[:net_paid_cents]).to eq(1700)
    paid.update!(status: :reversed)
    expect(described_class.new(2026).organizers).to be_empty
  end

  it "validates the selected calendar year" do
    ["garbage", "2026junk", 1900, 2101].each { |value| expect { described_class.new(value) }.to raise_error(ArgumentError) }
  end

  it "counts a successful live capture even when a failed test attempt exists" do
    at = Time.utc(2026, 10, 2)
    order = sale(at: at)
    create(:payment, order: order, status: :failed, provider_environment: "test")
    simulated = sale(at: at, environment: "simulate")
    allow(Rails.env).to receive(:production?).and_return(true)
    expect(Order.excluding_test_payments).to include(order)
    expect(Order.excluding_test_payments).not_to include(simulated)
    expect(Settlements::Calculator.new(event).send(:orders)).to include(order)
    expect(described_class.new(2026).organizers.sole[:gross_ticket_proceeds_cents]).to eq(2400)
  end

  it "reports legacy NULL-environment live sales and excludes payload-confirmed test payments" do
    at = Time.utc(2026, 10, 2)
    legacy = sale(at: at, environment: nil)
    create(:payment, order: legacy, status: :failed, provider_environment: "test")
    test_order = sale(at: at, environment: nil)
    test_order.payments.first.update!(provider_payload: { "livemode" => false })
    allow(Rails.env).to receive(:production?).and_return(true)

    expect(described_class.new(2026).organizers.sole[:gross_ticket_proceeds_cents]).to eq(2400)
    expect(described_class.new(2026).months[9][:gross_receipts_cents]).to eq(225)
    expect(Settlements::Calculator.new(event).send(:orders)).to include(legacy)
    expect(Settlements::Calculator.new(event).send(:orders)).not_to include(test_order)
  end

  it "loads organizer details only for organizations with period activity" do
    at = Time.utc(2026, 10, 2)
    sale(at: at)
    3.times { create(:organization) }
    report = described_class.new(2026)
    expect(Organization).to receive(:where).with(id: [organization.id]).and_call_original
    expect(report.organizers.map { |row| row[:organization_id] }).to eq([organization.id])
  end

  it "reconciles ticket, add-on and donation gross with a partial refund and paid payout" do
    at = Time.utc(2026, 10, 2)
    order = create(:order, :completed, event: event, completed_at: at, subtotal_cents: 4000,
      service_fee_cents: 225, total_cents: 4225)
    ticket = create(:order_item, order: order, unit_price_cents: 2500, subtotal_cents: 2500,
      fee_cents: 225, organizer_proceeds_cents: 2275)
    addon = create(:order_item, order: order, ticket_type: nil, catalog_item: create(:catalog_item, event: event),
      item_kind: :add_on, name: "Add-on", unit_price_cents: 1000, subtotal_cents: 1000, fee_cents: 0)
    create(:order_item, order: order, ticket_type: nil, catalog_item: create(:catalog_item, :donation, event: event),
      item_kind: :donation, name: "Donation", unit_price_cents: 500, subtotal_cents: 500, fee_cents: 0)
    payment = create(:payment, :succeeded, order: order, provider_environment: "live", created_at: at, succeeded_at: at)
    stamp!(payment, :capture_recorded_at, at, trigger: "payments_capture_recorded_at")
    create(:fee_component, order: order, kind: "platform", amount_cents: 225)
    returned = create(:refund, order: order, payment: payment, succeeded_at: at, amount_cents: 900)
    create(:refund_item, refund: returned, order_item: ticket, amount_cents: 500,
      organizer_proceeds_cents: 450, fee_cents: 50)
    create(:refund_item, refund: returned, order_item: addon, amount_cents: 400,
      organizer_proceeds_cents: 400, fee_cents: 0)
    account = create(:connected_account, organization: organization)
    create(:payout, event: event, organization: organization, connected_account: account,
      settlement: create(:settlement, event: event, organization: organization), status: :paid,
      amount_cents: 2925, paid_at: at)
    row = described_class.new(2026).organizers.sole
    expect(row).to include(gross_ticket_proceeds_cents: 2500, gross_add_on_proceeds_cents: 1000,
      gross_donation_proceeds_cents: 500, gross_non_ticket_proceeds_cents: 1500,
      ticket_refunds_cents: 500, non_ticket_refunds_cents: 400, fee_refunds_cents: 50,
      unallocated_refunds_cents: 0, fees_collected_cents: 225, reconciliation_adjustments_cents: 0, net_paid_cents: 2925)
    expect(row[:gross_ticket_proceeds_cents] + row[:gross_non_ticket_proceeds_cents] -
      row[:ticket_refunds_cents] - row[:non_ticket_refunds_cents] - row[:unallocated_refunds_cents] - row[:fees_collected_cents] +
      row[:fee_refunds_cents] + row[:reconciliation_adjustments_cents]).to eq(row[:net_paid_cents])
  end

  # A2 recheck finding 5 (e49e94d2). The annual organizer view keeps the
  # payout population verified at a0b25ffe: paid payouts on events with a
  # live or legacy capture from any provider (a Clover event's payout
  # included), while only the BPT detail restricts payouts to Stripe custody.
  # An ordinary refund is the organizer's only on the sale's own payment. The
  # same fixture runs through a frozen copy of a0b25ffe's reader.
  describe "annual organizer population across A1 and A2" do
    let(:a1) do
      Module.new.tap do |namespace|
        namespace.module_eval(Rails.root.join("spec/fixtures/never_fulfilled/a1_tax_reports_a0b25ffe.rb.txt").read)
      end.const_get(:TaxReports)
    end

    it "keeps the Clover payout, leaves the Stripe-only BPT rule alone and drops a refund on another payment" do
      at = Time.find_zone!("Pacific/Guam").local(2026, 10, 1)
      account = create(:connected_account, organization: organization)
      order = sale(at: at)
      create(:payout, event: event, organization: organization, connected_account: account,
        settlement: create(:settlement, event: event, organization: organization), amount_cents: 1700, status: :paid, paid_at: at)
      # A historical second live capture on the same order (not its
      # fulfilling payment), refunded: not organizer activity under A2.
      other = create(:payment, :succeeded, order: order, provider_environment: "live", succeeded_at: at)
      stamp!(other, :capture_recorded_at, nil, trigger: "payments_capture_recorded_at")
      other_refund = create(:refund, order: order, payment: other, succeeded_at: at + 1.day, amount_cents: 300)
      # CodeRabbit 4704013205: its refunded fee (an item written before the
      # A1 sale-ownership guard) is not in the monthly fee refunds either, so
      # monthly, annual and BPT read one refund population.
      connection = ActiveRecord::Base.connection
      connection.execute("ALTER TABLE refund_items DISABLE TRIGGER refund_items_sale_ownership")
      create(:refund_item, refund: other_refund, order_item: order.order_items.first, amount_cents: 40,
        organizer_proceeds_cents: 0, fee_cents: 40)
      connection.execute("ALTER TABLE refund_items ENABLE TRIGGER refund_items_sale_ownership")

      clover_event = create(:event, organization: organization, organizer_profile: profile)
      clover_order = create(:order, :completed, event: clover_event, completed_at: at)
      create(:order_item, order: clover_order, unit_price_cents: 900, subtotal_cents: 900, organizer_proceeds_cents: 900)
      clover_payment = create(:payment, :succeeded, order: clover_order, provider: "clover", provider_environment: "live",
        provider_payment_id: "clover_live_1", succeeded_at: at, created_at: at)
      stamp!(clover_payment, :capture_recorded_at, at, trigger: "payments_capture_recorded_at") if clover_payment.reload.capture_recorded_at
      clover_order.update!(fulfilled_by_payment_id: clover_payment.id)
      clover_payout = create(:payout, event: clover_event, organization: organization, connected_account: account,
        settlement: create(:settlement, event: clover_event, organization: organization), amount_cents: 800, status: :paid,
        paid_at: at + 2.days)

      test_event = create(:event, organization: organization, organizer_profile: profile)
      test_order = create(:order, :completed, event: test_event, completed_at: at)
      create(:payment, :succeeded, order: test_order, provider_environment: "test")
      create(:payout, event: test_event, organization: organization, connected_account: account,
        settlement: create(:settlement, event: test_event, organization: organization), amount_cents: 999, status: :paid, paid_at: at)

      before = a1.new(2026).organizers.sole
      after = described_class.new(2026).organizers.sole
      expect(before).to include(net_paid_cents: 2500, unallocated_refunds_cents: 260)
      expect(after).to include(net_paid_cents: 2500, unallocated_refunds_cents: 0)
      refund_keys = %i[unallocated_refunds_cents ticket_refunds_cents refunds_cents fee_refunds_cents fees_refunded_cents
        reconciliation_adjustments_cents]
      expect(after.except(*refund_keys)).to eq(before.except(*refund_keys))
      expect(after[:refunds_cents]).to eq(before[:refunds_cents] - 300)
      expect(after[:fee_refunds_cents]).to eq(before[:fee_refunds_cents] - 40)

      expect(a1.new(2026).months[9][:fees_refunded_cents]).to eq(40)
      expect(described_class.new(2026).months[9]).to include(fees_refunded_cents: 0)
      refunded_by_event = described_class.new(2026).bpt_event_rows(10).to_h { |row| [row[1], row[3]] }
      expect(refunded_by_event.values.sum).to eq(0)

      # BPT detail alone reads Stripe custody: the Clover payout stays out.
      paid_by_event = described_class.new(2026).bpt_event_rows(10).to_h { |row| [row[1], row.last] }
      expect(paid_by_event.fetch(event.id)).to be_positive
      expect(paid_by_event.fetch(clover_event.id, 0)).to eq(0)
      expect(PayoutCustody.bpt_payouts(Payout.where(id: clover_payout.id))).to be_empty
    end
  end

  # CodeRabbit 4704932984: ordinary processing is recognized at GREATEST(the
  # component's recording, the order's custody booking), the CPA rule
  # (design §5.3), independently of the sale's month, in the monthly and BPT
  # views alike. Regenerating January never moves a February cost into it.
  it "books a January sale's processing recorded in February in February, as the CPA does" do
    zone = Time.find_zone!("Pacific/Guam")
    january = zone.local(2026, 1, 15, 10)
    february = zone.local(2026, 2, 10, 10)
    late = sale(at: january)
    create(:fee_component, order: late, kind: "processing", estimated: false, amount_cents: 80, created_at: february)
    # Recorded before its sale was booked: recognized at the booking.
    early = sale(at: january)
    create(:fee_component, order: early, kind: "processing", estimated: false, amount_cents: 30, created_at: january - 5.days)

    report = described_class.new(2026)
    expect(report.months[0]).to include(card_processing_costs_cents: 30)
    expect(report.months[1]).to include(card_processing_costs_cents: 80, fees_collected_cents: 0)
    expect(report.months[0][:card_processing_costs_cents]).to eq(described_class.new(2026).months[0][:card_processing_costs_cents])
    costs = ->(month) { report.bpt_event_rows(month).to_h { |row| [row[1], row[5]] } }
    expect(costs.call(1)).to eq(event.id => 30)
    expect(costs.call(2)).to eq(event.id => 80)
    cpa = ->(month) { CpaMonthlyReport.new(2026, month).report[:rows].find { |row| row[:event_id] == event.id } }
    expect(cpa.call(1)).to include(stripe_processing_costs_cents: 30)
    expect(cpa.call(2)).to include(stripe_processing_costs_cents: 80)
  end

  # CodeRabbit 4704932992: a legacy capture with neither a recording stamp
  # nor a success time is not affirmative support for a historical payout.
  # Its payout leaves the annual view and is reported until finance freezes
  # it from the published baseline (payout_custody:derive); no period policy
  # is assumed.
  it "reports a payout whose only support is an untimed legacy capture until finance freezes its baseline" do
    at = Time.find_zone!("Pacific/Guam").local(2026, 10, 1)
    order = sale(at: at)
    payment = order.payments.sole
    stamp!(payment, :capture_recorded_at, nil, trigger: "payments_capture_recorded_at")
    Payment.where(id: payment.id).update_all(succeeded_at: nil)
    account = create(:connected_account, organization: organization)
    payout = create(:payout, event: event, organization: organization, connected_account: account,
      settlement: create(:settlement, event: event, organization: organization), amount_cents: 1700, status: :paid,
      paid_at: at + 1.day)

    report = described_class.new(2026)
    expect(report.organizers.sole).to include(net_paid_cents: 0)
    expect(report.as_json[:payout_population_alerts]).to eq([{ code: "payout_capture_time_unproven",
      payout_id: payout.id, event_id: event.id }])

    published = PayoutCustody.published_baseline("payout_id,included,source\n#{payout.id},true,bpt-export:2026-10\n")
    PayoutCustody.derive_history!(dry_run: false, authorized_by: "FIN-2026-11-001", published: published)
    expect(PayoutCustodyDetermination.find_by!(payout_id: payout.id)).to have_attributes(conservative_inclusion: true)
    report = described_class.new(2026)
    expect(report.organizers.sole).to include(net_paid_cents: 1700)
    expect(report.as_json[:payout_population_alerts]).to eq([])
  end
end
