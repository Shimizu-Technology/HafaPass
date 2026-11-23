# frozen_string_literal: true

require "rails_helper"

RSpec.describe EventSeriesReport, type: :service do
  let(:profile) { create(:organizer_profile, :verified) }
  let(:organization) { profile.organization }
  let(:owner) { profile.user }
  let(:series) do
    create(
      :event_series,
      organization: organization,
      name: "FD Alumni Tournament 2026",
      status: :active,
      revenue_share_bps: 1600,
      revenue_share_base: "admissions_net_proceeds",
      revenue_share_includes_door_cash: true,
      revenue_share_label: "School Share (16%)",
      primary_share_label: "Alumni Share (84%)"
    )
  end

  def create_paid_order!(
    event:,
    ticket_type:,
    pricing_tier: nil,
    quantity: 1,
    unit_price_cents: nil,
    discount_cents: 0,
    buyer_fee_cents: 150,
    organizer_fee_cents: 0,
    processing_fee_cents: 100,
    processing_bearer: "organizer",
    payment_method: "card",
    payment_provider: "stripe",
    provider_environment: "live",
    checked_in_count: 0,
    cancelled_tickets_count: 0
  )
    unit_price = unit_price_cents || pricing_tier&.price_cents || ticket_type.price_cents
    subtotal = unit_price * quantity
    proceeds = subtotal - discount_cents - organizer_fee_cents
    total = [subtotal + buyer_fee_cents - discount_cents, 0].max

    order = create(
      :order,
      event: event,
      status: :completed,
      subtotal_cents: subtotal,
      discount_cents: discount_cents,
      service_fee_cents: buyer_fee_cents,
      organizer_fee_cents: organizer_fee_cents,
      total_cents: total,
      payment_method: payment_method,
      processing_fee_bearer_snapshot: processing_bearer
    )
    item = create(
      :order_item,
      order: order,
      ticket_type: ticket_type,
      pricing_tier: pricing_tier,
      name: ticket_type.name,
      tier_name: pricing_tier&.name,
      unit_price_cents: unit_price,
      quantity: quantity,
      subtotal_cents: subtotal,
      discount_cents: discount_cents,
      fee_cents: buyer_fee_cents,
      organizer_fee_cents: organizer_fee_cents,
      organizer_proceeds_cents: proceeds
    )

    tickets = quantity.times.map do |idx|
      status = if idx < cancelled_tickets_count
        :cancelled
      elsif idx < cancelled_tickets_count + checked_in_count
        :checked_in
      else
        :issued
      end
      create(
        :ticket,
        order: order,
        order_item: item,
        ticket_type: ticket_type,
        pricing_tier: pricing_tier,
        event: event,
        status: status,
        checked_in_at: status == :checked_in ? Time.current : nil
      )
    end

    if buyer_fee_cents.positive? || organizer_fee_cents.positive?
      create(:fee_component, order: order, order_item: item, kind: "platform",
        amount_cents: buyer_fee_cents + organizer_fee_cents, estimated: true)
    end

    payment = create(
      :payment,
      :succeeded,
      order: order,
      provider: payment_provider,
      provider_environment: provider_environment,
      amount_cents: total
    )

    if processing_fee_cents.positive? && payment_provider == "stripe"
      component = create(
        :fee_component,
        order: order,
        order_item: item,
        kind: "processing",
        amount_cents: processing_fee_cents,
        estimated: false,
        provider_reference: "txn_#{SecureRandom.hex(6)}"
      )
      create(
        :stripe_fee_evidence,
        :verified,
        payment: payment,
        fee_component: component,
        provider_balance_transaction_id: component.provider_reference
      )
    end

    [order, item, tickets]
  end

  describe ".call" do
    let!(:night_one) do
      create(:event, :completed, organizer_profile: profile, organization: organization,
        title: "Night 1 - Pool Play", starts_at: 3.days.ago, ends_at: 2.days.ago)
    end
    let!(:championship_night) do
      create(:event, :published, organizer_profile: profile, organization: organization,
        title: "Championship Night", starts_at: 5.hours.ago, ends_at: 1.hour.ago, doors_open_at: 6.hours.ago)
    end
    let!(:pass_event) do
      create(:event, :completed, organizer_profile: profile, organization: organization,
        title: "Tournament Season Pass", starts_at: 10.days.ago, ends_at: 9.days.ago)
    end
    let!(:registration_event) do
      create(:event, :completed, organizer_profile: profile, organization: organization,
        title: "Team Registration", starts_at: 14.days.ago, ends_at: 13.days.ago)
    end

    let!(:ga_night_one) { create(:ticket_type, event: night_one, name: "General Admission", price_cents: 1000) }
    let!(:early_tier) { create(:pricing_tier, ticket_type: ga_night_one, name: "Early Bird", price_cents: 800, position: 0) }
    let!(:comp_night_one) { create(:ticket_type, event: night_one, name: "Sponsor Comp", price_cents: 0) }
    let!(:champ_ga) { create(:ticket_type, event: championship_night, name: "Championship GA", price_cents: 1500) }
    let!(:pass_tt) { create(:ticket_type, event: pass_event, name: "All-Access Pass", price_cents: 5000) }
    let!(:team_tt) { create(:ticket_type, event: registration_event, name: "Team Entry", price_cents: 30_000) }

    before do
      series.event_series_memberships.create!(event: night_one, role: :regular_night, position: 0)
      series.event_series_memberships.create!(event: championship_night, role: :championship_night, position: 1)
      series.event_series_memberships.create!(event: pass_event, role: :pass_sale, position: 2)
      series.event_series_memberships.create!(event: registration_event, role: :registration, position: 3)

      # Night 1:
      # 1) Online Stripe order with discount + buyer-paid fee + organizer-borne processing + partial refund
      order_online, item_online, _tickets_online = create_paid_order!(
        event: night_one,
        ticket_type: ga_night_one,
        pricing_tier: early_tier,
        quantity: 3,
        unit_price_cents: 800,
        discount_cents: 200,
        buyer_fee_cents: 240,
        organizer_fee_cents: 0,
        processing_fee_cents: 120,
        processing_bearer: "organizer",
        checked_in_count: 1,
        cancelled_tickets_count: 1
      )
      refund = create(:refund, :succeeded, order: order_online, payment: order_online.payments.first, amount_cents: 880)
      create(:refund_item, refund: refund, order_item: item_online, quantity: 1,
        organizer_proceeds_cents: 733, fee_cents: 80, organizer_fee_cents: 0, tax_cents: 67, amount_cents: 880)
      order_online.update!(status: :partially_refunded, refund_amount_cents: 880)

      # 2) Door cash order on Night 1 (detected via payment_method: "door_cash" + Payment provider: "door_cash")
      create_paid_order!(
        event: night_one,
        ticket_type: ga_night_one,
        quantity: 2,
        unit_price_cents: 1000,
        buyer_fee_cents: 0,
        organizer_fee_cents: 0,
        processing_fee_cents: 0,
        payment_method: "door_cash",
        payment_provider: "door_cash",
        checked_in_count: 2
      )

      # 3) Free / comp order on Night 1
      free_order = create(:order, event: night_one, status: :completed, subtotal_cents: 0,
        service_fee_cents: 0, discount_cents: 0, total_cents: 0, payment_method: nil)
      free_item = create(:order_item, order: free_order, ticket_type: comp_night_one, name: comp_night_one.name,
        unit_price_cents: 0, quantity: 2, subtotal_cents: 0, discount_cents: 0, fee_cents: 0, organizer_proceeds_cents: 0)
      create(:ticket, :checked_in, order: free_order, order_item: free_item, ticket_type: comp_night_one, event: night_one)
      create(:ticket, order: free_order, order_item: free_item, ticket_type: comp_night_one, event: night_one)

      # 4) Reserve holdback on Night 1 ($5.00)
      create(:balance_adjustment, organization: organization, event: night_one, kind: :reserve_hold,
        amount_cents: -500, status: :posted, effective_at: 1.day.ago, reason: "30-day reserve holdback")

      # Finalize Night 1 and pay out $5.00 partial payout
      settlement_n1 = Settlements::Finalizer.call(event: night_one, actor: owner)
      payout_n1 = create(:payout, organization: organization, event: night_one, settlement: settlement_n1,
        amount_cents: 500, status: :paid, paid_at: 1.hour.ago, provider_payout_id: "CHK-101-E#{night_one.id}")

      # Championship night (awaiting completion, not finalized, organizer-absorbed fee + platform-borne processing):
      create_paid_order!(
        event: championship_night,
        ticket_type: champ_ga,
        quantity: 2,
        unit_price_cents: 1500,
        buyer_fee_cents: 0,
        organizer_fee_cents: 300,
        processing_fee_cents: 117,
        processing_bearer: "platform",
        checked_in_count: 1
      )

      # Pass sale (finalized & ready for payout, odd-cent amount to exercise MoneyAllocator):
      create_paid_order!(
        event: pass_event,
        ticket_type: pass_tt,
        quantity: 1,
        unit_price_cents: 5001,
        buyer_fee_cents: 350,
        organizer_fee_cents: 0,
        processing_fee_cents: 185,
        processing_bearer: "platform",
        checked_in_count: 0
      )
      Settlements::Finalizer.call(event: pass_event, actor: owner)

      # Team Registration (separate group, excluded from admissions revenue share by default):
      create_paid_order!(
        event: registration_event,
        ticket_type: team_tt,
        quantity: 1,
        unit_price_cents: 30_000,
        buyer_fee_cents: 1500,
        organizer_fee_cents: 0,
        processing_fee_cents: 944,
        processing_bearer: "organizer",
        checked_in_count: 0
      )
      settlement_reg = Settlements::Finalizer.call(event: registration_event, actor: owner)
      create(:payout, organization: organization, event: registration_event, settlement: settlement_reg,
        connected_account: payout_n1.connected_account,
        amount_cents: settlement_reg.available_to_payout_cents, status: :paid, paid_at: 30.minutes.ago,
        provider_payout_id: "CHK-102-E#{registration_event.id}")
    end

    it "reconciles every member event to the exact cent with Settlements::Calculator and OrganizationFinanceSummary" do
      report = described_class.call(series)
      org_summary = OrganizationFinanceSummary.call(organization)
      org_rows_by_id = org_summary[:events].index_by { |row| row[:id] }

      expect(report[:events].map { |row| row[:event_id] }).to eq([
        night_one.id, championship_night.id, pass_event.id, registration_event.id
      ])

      reconciled_keys = %i[
        gross_cents discount_cents refund_cents platform_fee_cents processing_fee_cents
        platform_processing_fee_cents organizer_proceeds_cents sales_cents item_discount_cents
        absorbed_fee_cents refunded_proceeds_cents buyer_fee_cents door_cash_retained_cents
        reserve_cents other_adjustment_cents balance_cents payable_cents paid_cents
        in_flight_cents held_cents unresolved_buyer_liability_cents owed_cents
        negative_balance_cents awaiting_completion settlement_state payout_state
      ]

      report[:events].each do |row|
        event = Event.find(row[:event_id])
        calc = Settlements::Calculator.call(event).attributes
        org_row = org_rows_by_id.fetch(event.id)

        expect(row[:gross_cents]).to eq(calc[:gross_cents])
        expect(row[:organizer_proceeds_cents]).to eq(calc[:organizer_proceeds_cents])
        expect(row[:processing_fee_cents]).to eq(calc[:processing_fee_cents])
        expect(row[:platform_processing_fee_cents]).to eq(calc[:platform_processing_fee_cents])
        expect(row[:payable_cents]).to eq(calc[:payable_cents])

        reconciled_keys.each do |key|
          expect(row[key]).to eq(org_row[key]), "Expected event #{event.id} #{key} (#{row[key]}) to match OrganizationFinanceSummary (#{org_row[key]})"
        end
      end

      # Night 1 ticket counts: 2 non-cancelled online + 2 door cash = 4 direct paid; 2 free; 0 pass child; 4 checked in
      n1 = report[:events].first
      expect(n1).to include(
        tickets_issued_count: 6,
        direct_paid_tickets_count: 4,
        free_tickets_count: 2,
        pass_child_tickets_count: 0,
        checked_in_count: 4,
        door_cash_retained_cents: 2000,
        reserve_cents: 500
      )
      expect(n1[:direct_paid_tickets_count] + n1[:free_tickets_count] + n1[:pass_child_tickets_count]).to eq(n1[:tickets_issued_count])
    end

    it "computes group subtotals, channel breakdown, and ticket-type breakdown accurately" do
      report = described_class.call(series)

      admissions = report[:groups][:admissions]
      registration = report[:groups][:registration]
      combined = report[:groups][:combined]

      expect(admissions[:events_count]).to eq(3)
      expect(registration[:events_count]).to eq(1)
      expect(report[:groups][:other][:events_count]).to eq(0)
      expect(combined[:events_count]).to eq(4)
      expect(admissions[:organizer_proceeds_cents] + registration[:organizer_proceeds_cents]).to eq(combined[:organizer_proceeds_cents])
      expect(admissions[:gross_cents] + registration[:gross_cents]).to eq(combined[:gross_cents])

      # Channel breakdown sums cleanly to combined totals
      channels = report[:channels]
      expect(channels[:online_stripe][:orders_count]).to eq(4)
      expect(channels[:door_cash][:orders_count]).to eq(1)
      expect(channels[:door_cash][:door_cash_retained_cents]).to eq(2000)
      expect(channels[:door_cash][:organizer_proceeds_cents]).to eq(2000)
      expect(channels[:free_comp][:orders_count]).to eq(1)
      expect(channels[:free_comp][:tickets_issued_count]).to eq(2)
      expect(channels[:free_comp][:checked_in_count]).to eq(1)
      expect(channels[:free_comp][:gross_cents]).to eq(0)

      channel_proceeds_sum = channels.values.sum { |c| c[:organizer_proceeds_cents] }
      expect(channel_proceeds_sum).to eq(combined[:organizer_proceeds_cents])

      channel_tickets_sum = channels.values.sum { |c| c[:tickets_issued_count] }
      expect(channel_tickets_sum).to eq(combined[:tickets_issued_count])

      # Ticket-type breakdown splits Early Bird pricing tier from base GA on Night 1
      n1_tt_rows = report[:ticket_types].select { |r| r[:event_id] == night_one.id }
      early_row = n1_tt_rows.find { |r| r[:pricing_tier_id] == early_tier.id }
      door_row = n1_tt_rows.find { |r| r[:ticket_type_id] == ga_night_one.id && r[:pricing_tier_id].nil? }
      comp_row = n1_tt_rows.find { |r| r[:ticket_type_id] == comp_night_one.id }

      expect(early_row).to include(
        pricing_tier_name: "Early Bird",
        price_cents: 800,
        tickets_issued_count: 2,
        checked_in_count: 1,
        gross_cents: 2400,
        discount_cents: 200,
        refunded_proceeds_cents: 733,
        organizer_proceeds_cents: 1467
      )
      expect(door_row).to include(
        tickets_issued_count: 2,
        checked_in_count: 2,
        gross_cents: 2000,
        organizer_proceeds_cents: 2000
      )
      expect(comp_row).to include(
        tickets_issued_count: 2,
        checked_in_count: 1,
        gross_cents: 0,
        organizer_proceeds_cents: 0
      )
    end

    it "supports all 4 revenue_share_base modes, door_cash toggle, and zero-penny-drift allocation" do
      base_report = described_class.call(series)
      admissions = base_report[:groups][:admissions]
      combined = base_report[:groups][:combined]

      # 1. admissions_net_proceeds with door cash included (default)
      # Night 1 proceeds = (2200 - 733) + 2000 = 3467; Champ = 2700; Pass = 5001 -> 11168
      expect(admissions[:organizer_proceeds_cents]).to eq(11_168)
      rs = base_report[:revenue_share]
      expect(rs[:base_cents]).to eq(11_168)
      expect(rs[:share_cents] + rs[:primary_cents]).to eq(11_168)
      expect(rs[:share_cents]).to eq(1787) # 11168 * 1600 / 10000 = 1786.88 -> allocator gives remainder penny to index 0
      expect(rs[:primary_cents]).to eq(9381)
      expect(rs[:door_cash_retained_cents]).to eq(2000)

      # 1b. admissions_net_proceeds with door cash EXCLUDED
      series.update!(revenue_share_includes_door_cash: false)
      no_cash = described_class.call(series)[:revenue_share]
      expect(no_cash[:base_cents]).to eq(11_168 - 2000)
      expect(no_cash[:share_cents] + no_cash[:primary_cents]).to eq(no_cash[:base_cents])

      # 2. admissions_gross (gross - discount - ticket-only refunds across admissions; excludes refunded buyer fees/tax)
      series.update!(revenue_share_base: "admissions_gross", revenue_share_includes_door_cash: true)
      gross_rs = described_class.call(series)[:revenue_share]
      # Night 1: (2400 - 200 - 733) + 2000 = 3467; Champ = 3000; Pass = 5001 -> 11468
      expected_gross_base = 11_468
      expect(gross_rs[:base_cents]).to eq(expected_gross_base)
      expect(gross_rs[:share_cents] + gross_rs[:primary_cents]).to eq(expected_gross_base)

      # 3. admissions_net_after_processing
      series.update!(revenue_share_base: "admissions_net_after_processing", revenue_share_includes_door_cash: true)
      after_proc_rs = described_class.call(series)[:revenue_share]
      expected_after_proc = [admissions[:organizer_proceeds_cents] - admissions[:processing_fee_cents], 0].max
      expect(after_proc_rs[:base_cents]).to eq(expected_after_proc)
      expect(after_proc_rs[:share_cents] + after_proc_rs[:primary_cents]).to eq(expected_after_proc)

      # 4. all_net_proceeds (includes Team Registration)
      series.update!(revenue_share_base: "all_net_proceeds", revenue_share_includes_door_cash: true)
      all_rs = described_class.call(series)[:revenue_share]
      expect(all_rs[:base_cents]).to eq(combined[:organizer_proceeds_cents])
      expect(all_rs[:share_cents] + all_rs[:primary_cents]).to eq(combined[:organizer_proceeds_cents])

      # Odd-cent stress check across odd base values: zero penny drift
      series.update!(revenue_share_bps: 3333)
      odd_rs = described_class.call(series)[:revenue_share]
      expect(odd_rs[:revenue_share_bps] + odd_rs[:primary_share_bps]).to eq(10_000)
      expect(odd_rs[:share_cents] + odd_rs[:primary_cents]).to eq(odd_rs[:base_cents])
    end

    it "populates closeout checklist counts and payout guidance accurately" do
      checklist = described_class.call(series)[:closeout_checklist]

      expect(checklist).to include(
        events_total: 4,
        awaiting_completion_count: 1, # championship_night
        not_finalized_count: 1,       # championship_night
        changed_since_finalization_count: 0,
        ready_for_payout_count: 1,    # pass_event
        paid_count: 1,                # registration_event
        active_reserve_count: 1,      # night_one
        total_reserve_cents: 500,
        check_reference_pattern: "CHK-<check_number>-E<event_id>"
      )
      expect(checklist[:total_owed_cents]).to be > 0
      expect(checklist[:guidance]).to include("For check payouts, use CHK-<check_number>-E<event_id>")
      expect(checklist[:guidance]).not_to match(/30 days|bank transfer/i)
    end

    it "describes bank transfer closeout and reserve release under effective Copa terms" do
      allow(PolicyRegistry).to receive(:organizer_payout_terms).and_return("bank_transfer_with_reserve")

      guidance = described_class.call(series).dig(:closeout_checklist, :guidance)
      expect(guidance).to include("confirmed bank transfer reference", "chargeback reserve 30 days after the event",
        "For check payouts, use CHK-<check_number>-E<event_id>")
    end

    it "excludes Stripe test-mode payments in production across events, channels, and ticket types" do
      create_paid_order!(
        event: night_one,
        ticket_type: ga_night_one,
        quantity: 2,
        unit_price_cents: 1000,
        buyer_fee_cents: 200,
        processing_fee_cents: 90,
        provider_environment: "test",
        checked_in_count: 1
      )

      allow(Rails).to receive(:env).and_return(ActiveSupport::StringInquirer.new("production"))

      report = described_class.call(series)
      n1 = report[:events].find { |row| row[:event_id] == night_one.id }
      calc = Settlements::Calculator.call(night_one).attributes

      expect(n1[:gross_cents]).to eq(calc[:gross_cents])
      expect(n1[:organizer_proceeds_cents]).to eq(calc[:organizer_proceeds_cents])
      expect(n1[:tickets_issued_count]).to eq(6)
      expect(n1[:checked_in_count]).to eq(4)
      expect(report[:channels][:online_stripe][:orders_count]).to eq(4)
    end

    it "defaults revenue_share_bps to 1600 when nil and preserves explicit 0" do
      series.update!(revenue_share_bps: nil)
      defaulted = described_class.call(series)[:revenue_share]
      expect(defaulted[:revenue_share_bps]).to eq(1600)
      expect(defaulted[:primary_share_bps]).to eq(8400)

      series.update!(revenue_share_bps: 0)
      zeroed = described_class.call(series)[:revenue_share]
      expect(zeroed[:revenue_share_bps]).to eq(0)
      expect(zeroed[:share_cents]).to eq(0)
      expect(zeroed[:primary_cents]).to eq(zeroed[:base_cents])
    end

    it "handles an empty series gracefully without mutating settlements or payouts" do
      empty_series = create(:event_series, organization: organization, name: "Empty Series")
      expect {
        report = described_class.call(empty_series)
        expect(report[:events]).to eq([])
        expect(report[:ticket_types]).to eq([])
        expect(report[:groups][:combined][:gross_cents]).to eq(0)
        expect(report[:revenue_share][:base_cents]).to eq(0)
        expect(report[:revenue_share][:share_cents]).to eq(0)
        expect(report[:revenue_share][:primary_cents]).to eq(0)
        expect(report[:closeout_checklist][:events_total]).to eq(0)
      }.not_to change { [Settlement.count, Payout.count] }
    end

    it "nets refunds out of admissions_gross and excludes door cash in matching units" do
      gross_series = create(
        :event_series,
        organization: organization,
        name: "Gross Refund Check",
        status: :active,
        revenue_share_bps: 1600,
        revenue_share_base: "admissions_gross",
        revenue_share_includes_door_cash: false
      )
      ev = create(:event, :completed, organizer_profile: profile, organization: organization, title: "Refund Night")
      tt = create(:ticket_type, event: ev, name: "GA", price_cents: 5000)
      gross_series.event_series_memberships.create!(event: ev, role: :regular_night, position: 0)

      # Online order: $100 subtotal, $20 refunded -> $80 net gross
      online_order, online_item, _tickets = create_paid_order!(
        event: ev,
        ticket_type: tt,
        quantity: 2,
        unit_price_cents: 5000,
        buyer_fee_cents: 0,
        processing_fee_cents: 0
      )
      online_refund = create(:refund, :succeeded, order: online_order, payment: online_order.payments.first, amount_cents: 2000)
      create(:refund_item, refund: online_refund, order_item: online_item, quantity: 1,
        organizer_proceeds_cents: 2000, fee_cents: 0, organizer_fee_cents: 0, tax_cents: 0, amount_cents: 2000)
      online_order.update!(status: :partially_refunded, refund_amount_cents: 2000)

      # Fully refunded $100 door-cash order -> contributes $0 to base when door cash excluded OR included
      cash_order, cash_item, _cash_tickets = create_paid_order!(
        event: ev,
        ticket_type: tt,
        quantity: 2,
        unit_price_cents: 5000,
        buyer_fee_cents: 0,
        processing_fee_cents: 0,
        payment_method: "door_cash",
        payment_provider: "door_cash"
      )
      cash_refund = create(:refund, :succeeded, order: cash_order, payment: cash_order.payments.first, amount_cents: 10_000)
      create(:refund_item, refund: cash_refund, order_item: cash_item, quantity: 2,
        organizer_proceeds_cents: 10_000, fee_cents: 0, organizer_fee_cents: 0, tax_cents: 0, amount_cents: 10_000)
      cash_order.update!(status: :refunded, refund_amount_cents: 10_000)

      # Also a $30 non-refunded door-cash order -> excluded when revenue_share_includes_door_cash is false
      create_paid_order!(
        event: ev,
        ticket_type: tt,
        quantity: 1,
        unit_price_cents: 3000,
        buyer_fee_cents: 0,
        processing_fee_cents: 0,
        payment_method: "door_cash",
        payment_provider: "door_cash"
      )

      rs_excluded = described_class.call(gross_series)[:revenue_share]
      # Only the $80 net online order remains; refunded $100 cash order contributes $0, $30 cash order is excluded
      expect(rs_excluded[:base_cents]).to eq(8000)
      expect(rs_excluded[:share_cents]).to eq(1280)
      expect(rs_excluded[:primary_cents]).to eq(6720)

      gross_series.update!(revenue_share_includes_door_cash: true)
      rs_included = described_class.call(gross_series)[:revenue_share]
      # $80 online + $30 active cash = $110; refunded $100 cash order still contributes $0
      expect(rs_included[:base_cents]).to eq(11_000)
      expect(rs_included[:share_cents] + rs_included[:primary_cents]).to eq(11_000)
    end

    it "uses unbiased half-up rounding for revenue share allocation with zero penny drift" do
      rounding_series = create(
        :event_series,
        organization: organization,
        name: "Rounding Check",
        status: :active,
        revenue_share_bps: 1600,
        revenue_share_base: "admissions_net_proceeds",
        revenue_share_includes_door_cash: true
      )
      ev = create(:event, :completed, organizer_profile: profile, organization: organization, title: "Rounding Night")
      tt = create(:ticket_type, event: ev, name: "GA", price_cents: 10_001)
      rounding_series.event_series_memberships.create!(event: ev, role: :regular_night, position: 0)

      # 10_001 * 1600 / 10_000 = 1600.16 -> rounds to 1600 / 8401 (not biased to 1601 / 8400)
      create_paid_order!(
        event: ev,
        ticket_type: tt,
        quantity: 1,
        unit_price_cents: 10_001,
        buyer_fee_cents: 0,
        processing_fee_cents: 0
      )
      rs_low = described_class.call(rounding_series)[:revenue_share]
      expect(rs_low[:base_cents]).to eq(10_001)
      expect(rs_low[:share_cents]).to eq(1600)
      expect(rs_low[:primary_cents]).to eq(8401)
      expect(rs_low[:share_cents] + rs_low[:primary_cents]).to eq(10_001)

      # Add 3 cents -> base 10_004 * 1600 / 10_000 = 1600.64 -> rounds to 1601 / 8403
      create_paid_order!(
        event: ev,
        ticket_type: tt,
        quantity: 1,
        unit_price_cents: 3,
        buyer_fee_cents: 0,
        processing_fee_cents: 0
      )
      rs_high = described_class.call(rounding_series)[:revenue_share]
      expect(rs_high[:base_cents]).to eq(10_004)
      expect(rs_high[:share_cents]).to eq(1601)
      expect(rs_high[:primary_cents]).to eq(8403)
      expect(rs_high[:share_cents] + rs_high[:primary_cents]).to eq(10_004)
    end

    it "keeps upgraded tickets in the same ticket-type bucket as their order item" do
      upgrade_series = create(:event_series, organization: organization, name: "Upgrade Check", status: :active)
      ev = create(:event, :completed, organizer_profile: profile, organization: organization, title: "Upgrade Night")
      ga = create(:ticket_type, event: ev, name: "GA", price_cents: 1000)
      vip = create(:ticket_type, event: ev, name: "VIP", price_cents: 2500)
      upgrade_series.event_series_memberships.create!(event: ev, role: :regular_night, position: 0)

      _order, _item, tickets = create_paid_order!(
        event: ev,
        ticket_type: ga,
        quantity: 1,
        unit_price_cents: 1000,
        buyer_fee_cents: 0,
        processing_fee_cents: 0,
        checked_in_count: 1
      )
      # Simulate a ticket whose ticket_type was upgraded after purchase
      tickets.first.update!(ticket_type: vip)

      tt_rows = described_class.call(upgrade_series)[:ticket_types]
      expect(tt_rows.size).to eq(1)
      expect(tt_rows.first).to include(
        ticket_type_id: ga.id,
        tickets_issued_count: 1,
        checked_in_count: 1,
        gross_cents: 1000,
        organizer_proceeds_cents: 1000
      )
    end

    it "separates door_card box-office orders from online_stripe in the channel breakdown" do
      card_series = create(:event_series, organization: organization, name: "Door Card Check", status: :active)
      ev = create(:event, :completed, organizer_profile: profile, organization: organization, title: "Box Office Night")
      tt = create(:ticket_type, event: ev, name: "GA", price_cents: 2000)
      card_series.event_series_memberships.create!(event: ev, role: :regular_night, position: 0)

      create_paid_order!(
        event: ev,
        ticket_type: tt,
        quantity: 1,
        unit_price_cents: 2000,
        buyer_fee_cents: 150,
        processing_fee_cents: 100,
        payment_method: "card",
        payment_provider: "stripe"
      )
      create_paid_order!(
        event: ev,
        ticket_type: tt,
        quantity: 2,
        unit_price_cents: 2000,
        buyer_fee_cents: 0,
        processing_fee_cents: 0,
        payment_method: "door_card",
        payment_provider: "stripe"
      )

      channels = described_class.call(card_series)[:channels]
      expect(channels[:online_stripe]).to include(
        channel: "online_stripe",
        label: "Online (Stripe)",
        orders_count: 1,
        gross_cents: 2000,
        organizer_proceeds_cents: 2000
      )
      expect(channels[:door_card]).to include(
        channel: "door_card",
        label: "Door (Card)",
        orders_count: 1,
        gross_cents: 4000,
        organizer_proceeds_cents: 4000,
        door_cash_retained_cents: 0
      )
    end

    it "uses recorded item unit_price_cents and keeps distinct rows when a tier price changes after a sale" do
      price_series = create(:event_series, organization: organization, name: "Price Change Check", status: :active)
      ev = create(:event, :completed, organizer_profile: profile, organization: organization, title: "Dynamic Price Night")
      tt = create(:ticket_type, event: ev, name: "GA", price_cents: 1500)
      tier = create(:pricing_tier, ticket_type: tt, name: "Early Bird", price_cents: 1000, position: 0)
      price_series.event_series_memberships.create!(event: ev, role: :regular_night, position: 0)

      # Sale 1 at $10.00
      create_paid_order!(
        event: ev,
        ticket_type: tt,
        pricing_tier: tier,
        quantity: 2,
        unit_price_cents: 1000,
        buyer_fee_cents: 0,
        processing_fee_cents: 0,
        checked_in_count: 1
      )

      # Catalog tier price increases to $12.00 before Sale 2
      tier.update!(price_cents: 1200)
      create_paid_order!(
        event: ev,
        ticket_type: tt,
        pricing_tier: tier,
        quantity: 1,
        unit_price_cents: 1200,
        buyer_fee_cents: 0,
        processing_fee_cents: 0,
        checked_in_count: 1
      )

      tt_rows = described_class.call(price_series)[:ticket_types]
      expect(tt_rows.size).to eq(2)
      expect(tt_rows[0]).to include(
        pricing_tier_id: tier.id,
        price_cents: 1000,
        tickets_issued_count: 2,
        checked_in_count: 1,
        gross_cents: 2000,
        organizer_proceeds_cents: 2000
      )
      expect(tt_rows[1]).to include(
        pricing_tier_id: tier.id,
        price_cents: 1200,
        tickets_issued_count: 1,
        checked_in_count: 1,
        gross_cents: 1200,
        organizer_proceeds_cents: 1200
      )
    end

    it "subtracts only ticket consideration (not refunded buyer service fees) from admissions_gross" do
      fee_series = create(
        :event_series,
        organization: organization,
        name: "Fee-Inclusive Refund Gross Check",
        status: :active,
        revenue_share_bps: 1600,
        revenue_share_base: "admissions_gross",
        revenue_share_includes_door_cash: true
      )
      ev = create(:event, :completed, organizer_profile: profile, organization: organization, title: "Fee Refund Night")
      tt = create(:ticket_type, event: ev, name: "GA", price_cents: 1000)
      fee_series.event_series_memberships.create!(event: ev, role: :regular_night, position: 0)

      # Order 1: $10.00 admission + $1.50 buyer service fee (kept)
      create_paid_order!(
        event: ev,
        ticket_type: tt,
        quantity: 1,
        unit_price_cents: 1000,
        buyer_fee_cents: 150,
        processing_fee_cents: 0
      )

      # Order 2: $10.00 admission + $1.50 buyer service fee, fully refunded for $11.50
      refunded_order, refunded_item, _tickets = create_paid_order!(
        event: ev,
        ticket_type: tt,
        quantity: 1,
        unit_price_cents: 1000,
        buyer_fee_cents: 150,
        processing_fee_cents: 0
      )
      refund = create(:refund, :succeeded, order: refunded_order, payment: refunded_order.payments.first, amount_cents: 1150)
      create(:refund_item, refund: refund, order_item: refunded_item, quantity: 1,
        organizer_proceeds_cents: 1000, fee_cents: 150, organizer_fee_cents: 0, tax_cents: 0, amount_cents: 1150)
      refunded_order.update!(status: :refunded, refund_amount_cents: 1150)

      report = described_class.call(fee_series)
      rs = report[:revenue_share]

      # Settlement totals remain intact (gross 2000, buyer-total refund 1150, net proceeds 1000)
      expect(report[:groups][:admissions][:gross_cents]).to eq(2000)
      expect(report[:groups][:admissions][:refund_cents]).to eq(1150)
      expect(report[:groups][:admissions][:organizer_proceeds_cents]).to eq(1000)

      # admissions_gross base is $10.00 (1000 cents), NOT $8.50 (850 cents), and 16% split is on 1000
      expect(rs[:base_cents]).to eq(1000)
      expect(rs[:share_cents]).to eq(160)
      expect(rs[:primary_cents]).to eq(840)
      expect(rs[:share_cents] + rs[:primary_cents]).to eq(1000)
    end

    it "handles partial ticket/fee refunds, organizer-absorbed fees, unallocated refunds, and clamping safely in admissions_gross" do
      partial_series = create(
        :event_series,
        organization: organization,
        name: "Partial Refund Gross Check",
        status: :active,
        revenue_share_bps: 1600,
        revenue_share_base: "admissions_gross",
        revenue_share_includes_door_cash: true
      )
      ev = create(:event, :completed, organizer_profile: profile, organization: organization, title: "Partial Refund Night")
      tt = create(:ticket_type, event: ev, name: "GA", price_cents: 1000)
      partial_series.event_series_memberships.create!(event: ev, role: :regular_night, position: 0)

      # 1) Pro-rata partial refund: 2 x $10 tickets + $3.00 buyer fee; 1 ticket ($10) + $1.50 fee refunded -> $10.00 remains
      pro_rata_order, pro_rata_item, _t1 = create_paid_order!(
        event: ev, ticket_type: tt, quantity: 2, unit_price_cents: 1000, buyer_fee_cents: 300, processing_fee_cents: 0
      )
      pro_rata_refund = create(:refund, :succeeded, order: pro_rata_order, payment: pro_rata_order.payments.first, amount_cents: 1150)
      create(:refund_item, refund: pro_rata_refund, order_item: pro_rata_item, quantity: 1,
        organizer_proceeds_cents: 1000, fee_cents: 150, organizer_fee_cents: 0, tax_cents: 0, amount_cents: 1150)
      pro_rata_order.update!(status: :partially_refunded, refund_amount_cents: 1150)

      # 2) Ticket-only partial refund (fee not refunded): $10 ticket + $1.50 fee; $4.00 ticket-only refunded -> $6.00 remains
      ticket_only_order, ticket_only_item, _t2 = create_paid_order!(
        event: ev, ticket_type: tt, quantity: 1, unit_price_cents: 1000, buyer_fee_cents: 150, processing_fee_cents: 0
      )
      ticket_only_refund = create(:refund, :succeeded, order: ticket_only_order, payment: ticket_only_order.payments.first, amount_cents: 400)
      create(:refund_item, refund: ticket_only_refund, order_item: ticket_only_item, quantity: 0,
        organizer_proceeds_cents: 400, fee_cents: 0, organizer_fee_cents: 0, tax_cents: 0, amount_cents: 400)
      ticket_only_order.update!(status: :partially_refunded, refund_amount_cents: 400)

      # 3) Fee-only partial refund: $10 ticket + $1.50 fee; $1.50 fee refunded -> $10.00 remains
      fee_only_order, fee_only_item, _t3 = create_paid_order!(
        event: ev, ticket_type: tt, quantity: 1, unit_price_cents: 1000, buyer_fee_cents: 150, processing_fee_cents: 0
      )
      fee_only_refund = create(:refund, :succeeded, order: fee_only_order, payment: fee_only_order.payments.first, amount_cents: 150)
      create(:refund_item, refund: fee_only_refund, order_item: fee_only_item, quantity: 0,
        organizer_proceeds_cents: 0, fee_cents: 150, organizer_fee_cents: 0, tax_cents: 0, amount_cents: 150)
      fee_only_order.update!(status: :partially_refunded, refund_amount_cents: 150)

      # 4) Organizer-absorbed fee order: 2 x $10 tickets, $3.00 absorbed fee (proceeds $17.00);
      #    1 ticket refunded ($8.50 proceeds + $1.50 organizer_fee = $10.00 ticket consideration) -> $10.00 remains
      absorbed_order, absorbed_item, _t4 = create_paid_order!(
        event: ev, ticket_type: tt, quantity: 2, unit_price_cents: 1000,
        buyer_fee_cents: 0, organizer_fee_cents: 300, processing_fee_cents: 0
      )
      absorbed_refund = create(:refund, :succeeded, order: absorbed_order, payment: absorbed_order.payments.first, amount_cents: 1000)
      create(:refund_item, refund: absorbed_refund, order_item: absorbed_item, quantity: 1,
        organizer_proceeds_cents: 850, fee_cents: 0, organizer_fee_cents: 150, tax_cents: 0, amount_cents: 1000)
      absorbed_order.update!(status: :partially_refunded, refund_amount_cents: 1000)

      # 5) Legacy unallocated full refund (no RefundItem rows): $10 ticket + $1.50 fee, refunded $11.50 -> $0 remains (clamped cleanly)
      legacy_order, _legacy_item, _t5 = create_paid_order!(
        event: ev, ticket_type: tt, quantity: 1, unit_price_cents: 1000, buyer_fee_cents: 150, processing_fee_cents: 0
      )
      create(:refund, :succeeded, order: legacy_order, payment: legacy_order.payments.first, amount_cents: 1150)
      legacy_order.update!(status: :refunded, refund_amount_cents: 1150)

      rs = described_class.call(partial_series)[:revenue_share]
      # Remaining ticket gross: 1000 + 600 + 1000 + 1000 + 0 = 3600 cents
      expect(rs[:base_cents]).to eq(3600)
      expect(rs[:share_cents]).to eq(576)
      expect(rs[:primary_cents]).to eq(3024)
      expect(rs[:share_cents] + rs[:primary_cents]).to eq(3600)
    end

    it "subtracts ticket-only refunded amounts cleanly for door-cash refunds when include_door_cash is false" do
      cash_series = create(
        :event_series,
        organization: organization,
        name: "Door Cash Fee Refund Check",
        status: :active,
        revenue_share_bps: 1600,
        revenue_share_base: "admissions_gross",
        revenue_share_includes_door_cash: false
      )
      ev = create(:event, :completed, organizer_profile: profile, organization: organization, title: "Door Cash Night")
      tt = create(:ticket_type, event: ev, name: "GA", price_cents: 1000)
      cash_series.event_series_memberships.create!(event: ev, role: :regular_night, position: 0)

      # Online order: 2 x $10 tickets + $3.00 buyer fee; 1 ticket refunded ($11.50) -> $10.00 net online ticket gross
      online_order, online_item, _t1 = create_paid_order!(
        event: ev, ticket_type: tt, quantity: 2, unit_price_cents: 1000, buyer_fee_cents: 300, processing_fee_cents: 0
      )
      online_refund = create(:refund, :succeeded, order: online_order, payment: online_order.payments.first, amount_cents: 1150)
      create(:refund_item, refund: online_refund, order_item: online_item, quantity: 1,
        organizer_proceeds_cents: 1000, fee_cents: 150, organizer_fee_cents: 0, tax_cents: 0, amount_cents: 1150)
      online_order.update!(status: :partially_refunded, refund_amount_cents: 1150)

      # Door-cash order 1 (fee-inclusive refund edge case): 2 x $10 tickets + $3.00 fee; 1 ticket refunded ($11.50) -> $10.00 remaining door cash
      cash_fee_order, cash_fee_item, _t2 = create_paid_order!(
        event: ev, ticket_type: tt, quantity: 2, unit_price_cents: 1000, buyer_fee_cents: 300, processing_fee_cents: 0,
        payment_method: "door_cash", payment_provider: "door_cash"
      )
      cash_fee_refund = create(:refund, :succeeded, order: cash_fee_order, payment: cash_fee_order.payments.first, amount_cents: 1150)
      create(:refund_item, refund: cash_fee_refund, order_item: cash_fee_item, quantity: 1,
        organizer_proceeds_cents: 1000, fee_cents: 150, organizer_fee_cents: 0, tax_cents: 0, amount_cents: 1150)
      cash_fee_order.update!(status: :partially_refunded, refund_amount_cents: 1150)

      # Door-cash order 2 (fully refunded with fee): $10 ticket + $1.50 fee refunded ($11.50) -> $0 remaining door cash
      cash_full_order, cash_full_item, _t3 = create_paid_order!(
        event: ev, ticket_type: tt, quantity: 1, unit_price_cents: 1000, buyer_fee_cents: 150, processing_fee_cents: 0,
        payment_method: "door_cash", payment_provider: "door_cash"
      )
      cash_full_refund = create(:refund, :succeeded, order: cash_full_order, payment: cash_full_order.payments.first, amount_cents: 1150)
      create(:refund_item, refund: cash_full_refund, order_item: cash_full_item, quantity: 1,
        organizer_proceeds_cents: 1000, fee_cents: 150, organizer_fee_cents: 0, tax_cents: 0, amount_cents: 1150)
      cash_full_order.update!(status: :refunded, refund_amount_cents: 1150)

      rs_excluded = described_class.call(cash_series)[:revenue_share]
      # Excluding door cash leaves ONLY the $10.00 net online order (1000 cents)
      expect(rs_excluded[:base_cents]).to eq(1000)
      expect(rs_excluded[:share_cents]).to eq(160)
      expect(rs_excluded[:primary_cents]).to eq(840)

      cash_series.update!(revenue_share_includes_door_cash: true)
      rs_included = described_class.call(cash_series)[:revenue_share]
      # Including door cash adds the $10.00 remaining door-cash ticket gross -> 2000 cents
      expect(rs_included[:base_cents]).to eq(2000)
      expect(rs_included[:share_cents]).to eq(320)
      expect(rs_included[:primary_cents]).to eq(1680)
    end

    it "excludes door cash from the 16% revenue-share base by default on a new series while retaining door-cash visibility" do
      default_series = EventSeries.create!(
        organization: organization,
        name: "FD 2027 Default Door Cash Audit",
        status: :active,
        revenue_share_bps: 1600
      )
      expect(default_series.revenue_share_includes_door_cash).to be(false)

      pass_ev = create(:event, :published, organizer_profile: profile, organization: organization, title: "FD 2027 Passes")
      reg_ev = create(:event, :published, organizer_profile: profile, organization: organization, title: "FD 2027 Regular Night 1")
      champ_ev = create(:event, :published, organizer_profile: profile, organization: organization, title: "FD 2027 Championship Night 1")

      default_series.event_series_memberships.create!(event: pass_ev, role: :pass_sale, position: 0)
      default_series.event_series_memberships.create!(event: reg_ev, role: :regular_night, position: 1)
      default_series.event_series_memberships.create!(event: champ_ev, role: :championship_night, position: 2)

      reg_pass_tt = create(:ticket_type, event: pass_ev, name: "Regular Season Pass", price_cents: 5000)
      senior_pass_tt = create(:ticket_type, event: pass_ev, name: "Senior Season Pass", price_cents: 3500)
      kid_pass_tt = create(:ticket_type, event: pass_ev, name: "Kid Season Pass", price_cents: 2500)
      daily_tt = create(:ticket_type, event: reg_ev, name: "Paid Daily", price_cents: 1000)
      free_reg_tt = create(:ticket_type, event: reg_ev, name: "Alumni / FD Student", price_cents: 0)
      free_champ_tt = create(:ticket_type, event: champ_ev, name: "Alumni Championship", price_cents: 0)
      paid_champ_tt = create(:ticket_type, event: champ_ev, name: "Paid Championship", price_cents: 1500)

      # Online paid admissions = $50 + $35 + $25 + $15 = $125.00 (12500 cents)
      create_paid_order!(event: pass_ev, ticket_type: reg_pass_tt, processing_fee_cents: 0)
      create_paid_order!(event: pass_ev, ticket_type: senior_pass_tt, processing_fee_cents: 0)
      create_paid_order!(event: pass_ev, ticket_type: kid_pass_tt, processing_fee_cents: 0)
      create_paid_order!(event: champ_ev, ticket_type: paid_champ_tt, processing_fee_cents: 0)

      # $0 free alumni tickets (tracked in ticket counts, $0 revenue)
      create_paid_order!(event: reg_ev, ticket_type: free_reg_tt, unit_price_cents: 0, buyer_fee_cents: 0, processing_fee_cents: 0)
      create_paid_order!(event: champ_ev, ticket_type: free_champ_tt, unit_price_cents: 0, buyer_fee_cents: 0, processing_fee_cents: 0)

      # Box-office door_cash walk-up = $10.00 (1000 cents)
      create_paid_order!(
        event: reg_ev,
        ticket_type: daily_tt,
        buyer_fee_cents: 0,
        processing_fee_cents: 0,
        payment_method: "door_cash",
        payment_provider: "door_cash"
      )

      report = described_class.call(default_series)
      rs = report[:revenue_share]

      expect(rs[:revenue_share_includes_door_cash]).to be(false)
      expect(rs[:base_cents]).to eq(12_500)
      expect(rs[:share_cents]).to eq(2_000)
      expect(rs[:primary_cents]).to eq(10_500)
      expect(rs[:door_cash_retained_cents]).to eq(1_000)
      expect(report.dig(:channels, :free_comp, :gross_cents)).to eq(0)
      expect(report.dig(:channels, :free_comp, :tickets_issued_count)).to eq(2)
      expect(report.dig(:channels, :door_cash, :door_cash_retained_cents)).to eq(1_000)

      # Toggling door cash inclusion on includes the $10.00 walk-up -> $135.00 base
      default_series.update!(revenue_share_includes_door_cash: true)
      rs_with_cash = described_class.call(default_series)[:revenue_share]
      expect(rs_with_cash[:base_cents]).to eq(13_500)
      expect(rs_with_cash[:share_cents]).to eq(2_160)
      expect(rs_with_cash[:primary_cents]).to eq(11_340)
    end
  end
end
