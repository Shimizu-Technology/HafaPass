# frozen_string_literal: true

require "rails_helper"

RSpec.describe EventReportingService do
  let(:event) { create(:event, :published, timezone: "Pacific/Guam") }
  let(:general) { create(:ticket_type, event: event, name: "General", quantity_available: 20, quantity_sold: 3) }
  let(:team) { create(:ticket_type, event: event, name: "Team Registration") }

  def report(**filters)
    described_class.new(event: event, params: filters)
  end

  def answer(question, order, value, ticket: nil, options: question.options)
    RegistrationResponse.create!(registration_question: question, order: order, ticket: ticket,
      prompt_snapshot: question.prompt, kind_snapshot: RegistrationQuestion.kinds.fetch(question.kind),
      required_snapshot: false, options_snapshot: options, answer: { value: value }, answered_at: Time.current)
  end

  def buckets(result, question)
    result.find { |row| row[:question_id] == question.id }.fetch(:buckets)
  end

  it "uses price snapshots and ledger math, excluding pending and expired orders and isolating mixed order totals" do
    tier = create(:pricing_tier, ticket_type: general, name: "Current name", price_cents: 2200)
    order = create(:order, event: event, status: :partially_refunded, subtotal_cents: 7000, service_fee_cents: 400,
      discount_cents: 301, total_cents: 7099)
    early = create(:order_item, order: order, ticket_type: general, pricing_tier: tier, tier_name: "Early Bird",
      unit_price_cents: 2000, quantity: 2, discount_cents: 301, fee_cents: 200)
    regular = create(:order_item, order: order, ticket_type: team, unit_price_cents: 3000, fee_cents: 200)
    checked = create(:ticket, :checked_in, order: order, ticket_type: general, order_item: early, pricing_tier: tier)
    cancelled = create(:ticket, :cancelled, order: order, ticket_type: general, order_item: early, pricing_tier: tier)
    create(:ticket, order: order, ticket_type: team, order_item: regular)
    refund = create(:refund, order: order, amount_cents: 1950)
    create(:refund_item, refund: refund, order_item: early, amount_cents: 1950, organizer_proceeds_cents: 1850, fee_cents: 100, quantity: 1)
    RefundTicket.create!(refund: refund, ticket: cancelled, amount_cents: 1950)
    create(:refund, order: order, amount_cents: 100, status: :pending, succeeded_at: nil)
    %i[pending expired].each do |status|
      ignored = create(:order, event: event, status: status, completed_at: nil)
      create(:ticket, order: ignored, ticket_type: general)
    end

    result = report.sales
    expect(result[:summary]).to include(gross_sales_cents: 7000, net_sales_cents: 5149, unique_orders: 1,
      tickets_issued: 3, total_refunded_cents: 1950, discount_cents: 301)
    expect(result[:sales_by_tier]).to contain_exactly(
      a_hash_including(tier_name: "Early Bird", pricing_tier_id: tier.id, unit_price_cents: 2000, tickets_sold: 2,
        tickets_refunded_or_cancelled: 1, checked_in_count: 1, gross_cents: 4000, net_cents: 1949, remaining_capacity: 17),
      a_hash_including(tier_name: "Base price", pricing_tier_id: nil, unit_price_cents: 3000, tickets_sold: 1, net_cents: 3200)
    )
    expect(report(ticket_type_id: team.id).sales[:summary]).to include(gross_sales_cents: 3000,
      net_sales_cents: 3200, total_refunded_cents: 0, unique_orders: 1)
    expect(report(status: "checked_in").sales[:summary]).to include(net_sales_cents: 1949, tickets_issued: 1)
    expect(report(status: "checked_in").attendance[:total_active_tickets]).to eq(1)
    expect(checked).to be_checked_in
  end

  it "uses local 30-minute windows and excludes cancelled tickets and refunded, cancelled, or unsettled orders" do
    door = create(:order, event: event, source: "box_office", status: :partially_refunded)
    online = create(:order, event: event, source: "web")
    first = create(:ticket, :checked_in, order: door, ticket_type: general, checked_in_at: Time.utc(2026, 11, 23, 8, 29))
    create(:ticket, :checked_in, order: online, ticket_type: general, checked_in_at: first.checked_in_at - 5.minutes)
    create(:ticket, :checked_in, order: door, ticket_type: general, checked_in_at: Time.utc(2026, 11, 23, 8, 30))
    create(:ticket, order: door, ticket_type: team)
    create(:ticket, :cancelled, order: door, ticket_type: general, checked_in_at: first.checked_in_at)
    %i[pending expired refunded cancelled].each do |status|
      order = create(:order, event: event, status: status)
      create(:ticket, :checked_in, order: order, ticket_type: general, checked_in_at: first.checked_in_at)
    end

    expect(report.attendance).to include(total_active_tickets: 4, checked_in_count: 3, remaining_count: 1,
      check_in_rate: 75.0, timezone: "Pacific/Guam", pace: [
        { bucket_start: "2026-11-23T18:00:00+10:00", label: "6:00 PM", count: 2 },
        { bucket_start: "2026-11-23T18:30:00+10:00", label: "6:30 PM", count: 1 }
      ])
    expect(report(channel: "box_office", ticket_type_id: general.id).attendance).to include(
      total_active_tickets: 2, checked_in_count: 2, remaining_count: 0, check_in_rate: 100.0,
      by_ticket_type: [a_hash_including(ticket_type_name: "General", total_active_tickets: 2)])
    expect(report(channel: "online").attendance[:checked_in_count]).to eq(1)
    event.timezone = "Invalid/Zone"
    expect(report.attendance[:timezone]).to eq("Pacific/Guam")
  end

  it "excludes a retained or selected refund even when the ticket still says checked in" do
    order = create(:order, event: event, status: :partially_refunded)
    ticket = create(:ticket, :checked_in, order: order, ticket_type: general)
    refund = create(:refund, order: order)
    RefundTicket.create!(refund: refund, ticket: ticket, amount_cents: refund.amount_cents)
    expect(report.attendance).to include(total_active_tickets: 0, checked_in_count: 0, pace: [])
  end

  it "counts eligible respondents at the question grain and retains historical choices and false values" do
    order = create(:order, event: event, source: "box_office")
    online = create(:order, event: event)
    a = create(:ticket, order: order, ticket_type: general)
    b = create(:ticket, order: order, ticket_type: general)
    c = create(:ticket, order: online, ticket_type: team)
    cancelled = create(:ticket, :cancelled, order: order, ticket_type: general)
    refunded_order = create(:order, event: event, status: :refunded)
    refunded_ticket = create(:ticket, order: refunded_order, ticket_type: general)
    pending_order = create(:order, event: event, status: :pending)
    pending_ticket = create(:ticket, order: pending_order, ticket_type: general)
    shirts = create(:registration_question, event: event, scope: :ticket, kind: :selection, options: %w[M L])
    choices = create(:registration_question, event: event, scope: :ticket, kind: :multi_select, options: %w[Golf Dinner])
    year = create(:registration_question, event: event, scope: :ticket, kind: :number, ticket_type_ids: [general.id])
    confirm = create(:registration_question, event: event, scope: :ticket, kind: :checkbox)
    name = create(:registration_question, event: event, kind: :short_text, active: false)
    answer(shirts, order, "XL", ticket: a, options: %w[M L XL])
    answer(shirts, order, "L", ticket: b)
    answer(shirts, order, "M", ticket: cancelled)
    answer(shirts, refunded_order, "M", ticket: refunded_ticket)
    answer(shirts, pending_order, "M", ticket: pending_ticket)
    answer(choices, order, %w[Golf Dinner], ticket: a)
    answer(choices, order, ["Golf"], ticket: b)
    answer(year, order, 1998, ticket: a)
    answer(year, order, 2027, ticket: b)
    answer(confirm, order, true, ticket: a)
    answer(confirm, order, false, ticket: b)
    answer(name, order, " Class of 1998 ")
    answer(name, online, "class OF 1998")
    answer(confirm, online, nil, ticket: c)

    rows = report.registrations.demographics
    expect(rows.find { |row| row[:question_id] == shirts.id }).to include(total_responses: 2, blank_or_unanswered_count: 1)
    expect(buckets(rows, shirts)).to eq([
      { value: "L", label: "L", count: 1, percentage: 50.0 },
      { value: "XL", label: "XL", count: 1, percentage: 50.0 },
      { value: "M", label: "M", count: 0, percentage: 0.0 }
    ])
    expect(buckets(rows, choices)).to match([
      a_hash_including(value: "Golf", count: 2, percentage: 100.0),
      a_hash_including(value: "Dinner", count: 1, percentage: 50.0)
    ])
    expect(buckets(rows, confirm).map { |bucket| bucket.values_at(:label, :count) }).to contain_exactly(["Yes", 1], ["No", 1])
    expect(buckets(rows, year).pluck(:value)).to eq([1998, 2027])
    expect(buckets(rows, name)).to match([a_hash_including(value: "class of 1998", count: 2)])
    door = report(channel: "box_office", ticket_type_id: general.id).registrations.demographics
    expect(buckets(door, name)).to match([a_hash_including(count: 1)])
    expect(report(ticket_type_id: team.id).registrations.demographics.find { |row| row[:question_id] == year.id })
      .to include(total_responses: 0, blank_or_unanswered_count: 0, ticket_type_ids: [general.id])
  end

  it "rejects a ticket type from another event and invalid filters" do
    expect { report(ticket_type_id: create(:ticket_type).id) }.to raise_error(OrganizerSalesQuery::InvalidFilter, "Invalid ticket type")
    expect { report(status: "other") }.to raise_error(OrganizerSalesQuery::InvalidFilter, "Invalid status")
    expect { report(channel: "other") }.to raise_error(OrganizerSalesQuery::InvalidFilter, "Invalid channel")
  end
end
