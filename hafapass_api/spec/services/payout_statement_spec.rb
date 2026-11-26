# frozen_string_literal: true

require "rails_helper"

# Statement math: every line is regrouped from the settlement calculator's own
# items and every total is the calculator's, so the lines must always add up.
RSpec.describe PayoutStatement do
  include ActiveSupport::Testing::TimeHelpers

  let(:admin) { create(:user, :admin) }
  let(:profile) { create(:organizer_profile, :verified) }
  let(:organization) { profile.organization }
  let(:event) do
    create(:event, :completed, organization: organization, organizer_profile: profile,
      starts_at: guam(2027, 1, 30, 9), ends_at: guam(2027, 1, 30, 18))
  end
  let(:adult) { create(:ticket_type, event: event, name: "Adult", price_cents: 1700) }
  let(:child) { create(:ticket_type, event: event, name: "Child", price_cents: 1200) }

  around { |example| travel_to(guam(2027, 2, 2, 10)) { example.run } }

  def build_statement(target = event, **)
    described_class.call(event: target, **)
  end

  def line(statement, label)
    statement[:sections].flat_map { |section| section[:lines] }.find { |entry| entry[:label] == label }
  end

  # A manual bank transfer finance approved but has not sent is not "being
  # sent"; one with a real reference, or paid, has left.
  it "labels an approved manual transfer not sent yet, and marks only real dispatches" do
    record_card_sale!(event, ticket_type: adult, quantity: 3)
    approved_bank_account!(organization, actor: profile.user, admin: admin)
    allow(PayoutGateway).to receive(:submit) { |payout| PayoutGateway::Result.new(provider_payout_id: "manual_po_#{payout.id}", status: :processing) }
    payout = PayoutCreator.call(settlement: Settlements::Finalizer.call(event: event, actor: admin), actor: admin,
      idempotency_key: "statement-dispatch", amount_cents: 1000)
    transfer = -> { build_statement[:transfers].sole.slice(:status, :status_label, :dispatched) }
    expect(transfer.call).to eq(status: "processing", status_label: "Approved, not sent yet", dispatched: false)
    payout.update_columns(provider_payout_id: "bank-ref-123")
    expect(transfer.call).to eq(status: "processing", status_label: "Being sent", dispatched: true)
  end

  # A2 recheck finding 4 (e49e94d2): one dispatched transfer never makes an
  # unsent one "sent". Mixed $10 sent / $20 unsent, and a real paid one.
  it "splits in-flight money into what has left and what has not" do
    record_card_sale!(event, ticket_type: adult, quantity: 3)
    approved_bank_account!(organization, actor: profile.user, admin: admin)
    allow(PayoutGateway).to receive(:submit) { |payout| PayoutGateway::Result.new(provider_payout_id: "manual_po_#{payout.id}", status: :processing) }
    sent, unsent, paid = [[1000, "split-sent"], [2000, "split-unsent"], [500, "split-paid"]].map do |amount, key|
      PayoutCreator.call(settlement: Settlements::Finalizer.call(event: event, actor: admin), actor: admin,
        idempotency_key: key, amount_cents: amount)
    end
    sent.update_columns(provider_payout_id: "bank-ref-10")
    paid.update_columns(provider_payout_id: "bank-ref-5")

    totals = build_statement[:totals]
    expect(totals).to include(in_progress_cents: 3500, in_progress_sent_cents: 1500, in_progress_unsent_cents: 2000)
    # Recorded paid (the fixture skips the custody row's own trigger).
    ActiveRecord::Base.connection.execute("ALTER TABLE payouts DISABLE TRIGGER payouts_require_custody")
    paid.update_columns(status: Payout.statuses[:paid], paid_at: Time.current)
    ActiveRecord::Base.connection.execute("ALTER TABLE payouts ENABLE TRIGGER payouts_require_custody")
    statement = build_statement
    expect(statement[:totals]).to include(transferred_cents: 500, in_progress_cents: 3000, in_progress_sent_cents: 1000,
      in_progress_unsent_cents: 2000)
    expect(statement[:transfers].map { |transfer| [transfer[:amount_cents], transfer[:dispatched]] })
      .to eq([[1000, true], [2000, false], [500, true]])
    expect(unsent.reload.provider_payout_id).to eq("manual_po_#{unsent.id}")
    expect(statement[:reconciles]).to be(true)
  end

  it "breaks gross sales down by ticket and shows who paid each fee" do
    record_card_sale!(event, ticket_type: adult, quantity: 3, buyer_fee_cents: 100, processing_fee_cents: 180)
    record_card_sale!(event, ticket_type: child, quantity: 2, buyer_fee_cents: 0, organizer_fee_cents: 160,
      processing_fee_cents: 0)
    record_card_sale!(event, ticket_type: adult, quantity: 1, discount_cents: 500, buyer_fee_cents: 100,
      processing_fee_cents: 40, bearer: "platform")

    statement = build_statement
    expect(statement[:sales_by_ticket]).to eq([
      { name: "Adult", quantity: 4, gross_cents: 6800, discount_cents: 500, proceeds_cents: 6300 },
      { name: "Child", quantity: 2, gross_cents: 2400, discount_cents: 0, proceeds_cents: 2240 }
    ])
    expect(line(statement, "Ticket sales")[:amount_cents]).to eq(9200)
    expect(line(statement, "Discounts and promo codes")[:amount_cents]).to eq(-500)
    expect(line(statement, "HåfaPass fees you covered")[:amount_cents]).to eq(-160)
    # The platform-bearer order's processing is covered by HåfaPass.
    expect(line(statement, "Card processing")).to include(amount_cents: -180)
    expect(line(statement, "Card processing")[:note]).to include("HåfaPass covered $0.40")
    expect(statement[:totals]).to include(buyer_paid_fees_cents: 400, processing_covered_by_hafapass_cents: 40,
      net_proceeds_cents: 8360)
    expect(statement[:notes].first).to include("Buyers paid $4.00 in HåfaPass fees")
    expect_statement_to_reconcile(statement, event)
  end

  it "says plainly that door cash stays with the organizer" do
    published = create(:event, :published, organization: organization, organizer_profile: profile,
      starts_at: 1.hour.ago, ends_at: 3.hours.from_now)
    general = create(:ticket_type, event: published, price_cents: 2000)
    record_door_cash_sale!(published, ticket_type: general, user: profile.user, quantity: 2)
    record_card_sale!(published, ticket_type: general, quantity: 1, processing_fee_cents: 88)

    statement = build_statement(published)
    expect(statement[:status_label]).to eq("Sales open")
    expect(line(statement, "Door cash you collected")).to include(amount_cents: -4000,
      note: "You already have this cash, so it is not part of the bank transfer.")
    expect(statement[:notes]).to include("Door cash ($40.00) stays with you and is not included in any bank transfer.")
    expect(statement[:totals][:available_cents]).to eq(2000 - 88)
    expect_statement_to_reconcile(statement, published)
  end

  it "handles zero sales" do
    statement = build_statement
    expect(statement).to include(status: "final", status_label: "Final", reconciles: true, sales_by_ticket: [])
    expect(statement[:totals]).to include(gross_cents: 0, available_cents: 0, balance_remaining_cents: 0)
    expect(statement[:transfers]).to eq([])
    expect_statement_to_reconcile(statement, event)
  end

  it "handles a 100% refunded event" do
    order, item, capture = record_card_sale!(event, ticket_type: adult, quantity: 2, processing_fee_cents: 0)
    record_card_refund!(order, item, capture, proceeds_cents: 3400, fee_cents: 200, quantity: 2)

    statement = build_statement
    expect(line(statement, "Refunds")).to include(amount_cents: -3400)
    expect(line(statement, "Refunds")[:note]).to include("Buyers got back $36.00")
    expect(statement[:totals]).to include(ticket_proceeds_cents: 0, net_proceeds_cents: 0, buyer_paid_fees_cents: 0)
    expect(statement[:status]).to eq("final")
    expect_statement_to_reconcile(statement, event)
  end

  it "shows a negative balance after chargebacks exceed what is left" do
    approved_bank_account!(organization, actor: profile.user, admin: admin)
    allow(PayoutGateway).to receive(:submit) { |payout| PayoutGateway::Result.new(provider_payout_id: "manual_po_#{payout.id}", status: :processing) }
    orders = Array.new(3) { record_card_sale!(event, ticket_type: adult, quantity: 2, processing_fee_cents: 50) }
    PayoutReserves.hold!(event: event, actor: admin)
    settlement = Settlements::Finalizer.call(event: event, actor: admin)
    payout = PayoutCreator.call(settlement: settlement, actor: admin, idempotency_key: "negative-balance")
    PayoutCustody.record!(payout, basis: "recorded_at_paid")
    payout.update_columns(status: Payout.statuses[:paid], provider_payout_id: "TRF-NEG", paid_at: Time.current)
    orders.first(2).each { |order, _item, capture| record_lost_chargeback!(order, capture) }

    statement = build_statement
    expect(line(statement, "Chargebacks")).to include(amount_cents: -7200)
    # $102.00 sold − $1.50 processing = $100.50; $10.05 held; $90.45 sent;
    # then two $36.00 chargebacks.
    expect(statement[:totals]).to include(net_proceeds_cents: 2850, reserve_held_cents: 1005,
      transferred_cents: 9045, balance_remaining_cents: -7200)
    expect(statement[:status]).to eq("reserve_held")
    # The $10.05 reserve absorbs part of the $72.00 in chargebacks.
    expect(statement[:totals][:still_to_come_cents]).to eq(-7200 + 1005)
    expect(statement[:notes].last).to include("you owe $61.95, even after your $10.05 reserve.")
    expect_statement_to_reconcile(statement, event)
  end

  # Finding 5 of the PR #239 review: a refund after the payout that the reserve
  # covers is not a debt. "You owe" is decided with the reserve included.
  it "does not say the organizer owes money the held reserve still covers" do
    approved_bank_account!(organization, actor: profile.user, admin: admin)
    allow(PayoutGateway).to receive(:submit) { |payout| PayoutGateway::Result.new(provider_payout_id: "manual_po_#{payout.id}", status: :processing) }
    big = create(:ticket_type, event: event, name: "Adult", price_cents: 9900)
    order, item, capture = record_card_sale!(event, ticket_type: big, quantity: 1, processing_fee_cents: 300, bearer: "platform")
    PayoutReserves.hold!(event: event, actor: admin)
    settlement = Settlements::Finalizer.call(event: event, actor: admin)
    payout = PayoutCreator.call(settlement: settlement, actor: admin, idempotency_key: "covered-refund")
    expect(payout.amount_cents).to eq(8910)
    PayoutCustody.record!(payout, basis: "recorded_at_paid")
    payout.update_columns(status: Payout.statuses[:paid], provider_payout_id: "TRF-COVERED", paid_at: Time.current)
    record_card_refund!(order, item, capture, proceeds_cents: 500)

    statement = build_statement
    expect(statement[:totals]).to include(balance_remaining_cents: -500, reserve_held_cents: 990, still_to_come_cents: 490)
    expect(statement[:closing]).to eq(
      lines: [
        { label: "Balance after transfers, not counting the reserve", amount_cents: -500, note: nil },
        { label: "Reserve still held", amount_cents: 990, note: "Comes back to you on Mar 1, 2027, less any later refunds or chargebacks." }
      ],
      total_label: "Still to come", total_cents: 490
    )
    expect(statement[:notes].join(" ")).not_to include("you owe")
    expect(statement[:notes]).to include("Refunds or chargebacks after your payout ($5.00) come out of your $9.90 reserve. " \
      "You will get the remaining $4.90 when it is released.")
    expect(statement[:contradictions]).to eq([])
    expect_statement_to_reconcile(statement, event)

    # Bigger than the reserve: now it is a debt, said once, with the reserve counted.
    record_lost_chargeback!(order, capture, amount_cents: 2000)
    owing = build_statement
    expect(owing[:closing]).to include(total_label: "You owe", total_cents: 490 - 2000)
    expect(owing[:notes].last).to include("you owe $15.10, even after your $9.90 reserve")
    expect_statement_to_reconcile(owing, event)
  end

  it "flags a statement whose words contradict its numbers" do
    record_card_sale!(event, ticket_type: adult, quantity: 1, processing_fee_cents: 0)
    statement = described_class.new(event: event)
    allow(statement).to receive(:notes).and_return(["Chargebacks or refunds after your payout mean you owe $1.00."])
    expect(statement.call).to include(reconciles: false, contradictions: ["owe_note_mismatch"])
  end

  it "keeps exact cents on a $1,000,000.00 event" do
    big = create(:ticket_type, event: event, name: "Championship table", price_cents: 100_000_00)
    record_card_sale!(event, ticket_type: big, quantity: 10, buyer_fee_cents: 0, processing_fee_cents: 29_000_00)

    statement = build_statement
    expect(line(statement, "Ticket sales")[:amount_cents]).to eq(1_000_000_00)
    expect(statement[:totals][:net_proceeds_cents]).to eq(971_000_00)
    expect(PayoutSchedule.for(event).suggested_reserve_cents).to eq(97_100_00)
    expect_statement_to_reconcile(statement, event)
  end

  it "treats a multi-day pass event as ended only after its last night" do
    pass_event = create(:event, :published, organization: organization, organizer_profile: profile,
      title: "Three-night festival pass", starts_at: guam(2027, 1, 29, 18), ends_at: guam(2027, 1, 29, 23))
    nights = [30, 31].map do |day|
      create(:event, :published, organization: organization, organizer_profile: profile,
        starts_at: guam(2027, 1, day, 18), ends_at: guam(2027, 1, day, 23))
    end
    pass = create(:ticket_type, event: pass_event, name: "All nights", price_cents: 4500, is_pass: true)
    nights.each_with_index { |night, index| TicketTypeIncludedEvent.create!(ticket_type: pass, included_event: night, position: index) }
    record_card_sale!(pass_event, ticket_type: pass, quantity: 2, processing_fee_cents: 0)

    statement = build_statement(pass_event, at: guam(2027, 1, 30, 9))
    expect(statement[:event]).to include(multi_day: true)
    expect(statement[:status]).to eq("sales_open")

    statement = build_statement(pass_event, at: guam(2027, 2, 1, 9))
    expect(statement[:status]).to eq("waiting_for_payout")
    expect(statement[:schedule]).to include(ended_on: Date.new(2027, 1, 31), transfer_expected_by: Date.new(2027, 2, 3),
      reserve_release_on: Date.new(2027, 3, 2))
    expect_statement_to_reconcile(statement, pass_event)
  end

  it "keeps long names intact" do
    long_name = "#{"Fictional Inter-Island Brazilian Jiu-Jitsu Spectator Admission " * 4}🥋"
    long_type = create(:ticket_type, event: event, name: long_name, price_cents: 1500)
    record_card_sale!(event, ticket_type: long_type, quantity: 1, processing_fee_cents: 0)
    expect(build_statement[:sales_by_ticket].sole[:name]).to eq(long_name)
  end
end
