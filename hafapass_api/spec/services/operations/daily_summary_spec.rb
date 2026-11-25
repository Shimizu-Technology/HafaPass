# frozen_string_literal: true

require "rails_helper"

RSpec.describe Operations::DailySummary do
  let(:guam) { ActiveSupport::TimeZone["Pacific/Guam"] }
  # 11:00 Guam on Jan 6 2027, so the previous Guam day is Jan 5.
  let(:now) { guam.local(2027, 1, 6, 11, 0) }
  let(:noon_jan5) { guam.local(2027, 1, 5, 12, 0) }
  let(:organizer_profile) { create(:organizer_profile) }
  let(:event) { create(:event, :published, title: "Copa de Marianas", organizer_profile: organizer_profile, max_capacity: 900) }

  def sold_order(event:, at:, total: 1700, method: nil)
    order = create(:order, event: event, completed_at: at, subtotal_cents: total - 100, service_fee_cents: 100,
      total_cents: total, payment_method: method, buyer_name: "Zed Buyerson", buyer_email: "zed.buyerson@example.com",
      buyer_phone: "6715550199")
    create(:ticket, order: order, event: event, ticket_type: create(:ticket_type, event: event), attendee_name: "Pat Attendee",
      attendee_email: "pat.attendee@example.com")
    FeeComponent.create!(order: order, kind: "platform", amount_cents: 100, currency: "usd")
    FeeComponent.create!(order: order, kind: "processing", amount_cents: 80, currency: "usd")
    order
  end

  let!(:online) { sold_order(event: event, at: noon_jan5) }
  let!(:cash) { sold_order(event: event, at: noon_jan5 + 2.hours, total: 1200, method: "door_cash") }
  let(:summary) { described_class.call(now: now) }

  before do
    sold_order(event: event, at: guam.local(2027, 1, 4, 23, 59, 59))
    sold_order(event: event, at: guam.local(2027, 1, 6, 0, 0, 0))
    create(:order, :pending, event: event)
  end

  it "uses the previous full Guam day, with its boundaries in Guam time" do
    expect(summary[:guam_date]).to eq("2027-01-05")
    expect(summary[:window]).to include(starts_at: "2027-01-05T00:00:00+10:00", ends_at: "2027-01-06T00:00:00+10:00", partial: false)
    expect(summary[:sales][:orders]).to eq(2)
  end

  it "totals sales, tickets, fees and the door cash / online split, in total and by event" do
    expect(summary[:sales]).to include(orders: 2, tickets: 2, gross_cents: 2900, refund_cents: 0,
      fees_cents: { "platform" => 200, "processing" => 160, "tax" => 0, "organizer" => 0 },
      door_cash: { orders: 1, gross_cents: 1200 }, online: { orders: 1, gross_cents: 1700 })
    expect(summary[:events]).to eq([{ event_id: event.id, title: "Copa de Marianas", orders: 2, tickets: 2, gross_cents: 2900,
      refund_cents: 0, fees_cents: 360, door_cash_gross_cents: 1200, online_gross_cents: 1700 }])
  end

  it "counts refunds that succeeded that day, even for earlier orders, and not other days" do
    create(:refund, order: online, amount_cents: 500, succeeded_at: noon_jan5 + 3.hours)
    create(:refund, order: online, amount_cents: 900, succeeded_at: noon_jan5 + 1.day)
    expect(summary[:sales]).to include(refund_cents: 500, refund_count: 1)
    expect(summary[:events].first).to include(refund_cents: 500)
  end

  it "supports a chosen date and today so far, and rejects bad or future dates" do
    expect(described_class.call(date: "2027-01-04", now: now)[:sales][:orders]).to eq(1)
    today = described_class.call(date: "today", now: now)
    expect(today).to include(guam_date: "2027-01-06")
    expect(today[:window][:partial]).to be(true)
    expect { described_class.call(date: "2027-02-01", now: now) }.to raise_error(ArgumentError, /future/)
    expect { described_class.call(date: "01/05/2027", now: now) }.to raise_error(ArgumentError, /YYYY-MM-DD/)
  end

  it "lists capacity left on events that are selling" do
    ticket_type = create(:ticket_type, event: event, name: "Adult", quantity_available: 100, quantity_sold: 40)
    create(:event, :draft, title: "Not selling") if Event.statuses.key?("draft")
    on_sale = described_class.call(now: Time.current).fetch(:on_sale)
    row = on_sale.find { |entry| entry[:event_id] == event.id }
    expect(row).to include(title: "Copa de Marianas", max_capacity: 900)
    expect(row[:capacity_remaining]).to be_between(0, 900)
    expect(row[:ticket_types]).to include(include(name: "Adult", remaining: 60)) if ticket_type
    expect(on_sale.map { |entry| entry[:title] }).not_to include("Not selling")
  end

  it "includes webhook, queue and signal health" do
    health = summary[:health]
    expect(health).to include(:readiness, :checks, :stripe_webhooks, :operational_signals, :job_queue, :error_counts)
    expect(health[:stripe_webhooks]).to include(:last_receipt_at, :silent, :failing)
    expect(health[:operational_signals]).to include("stripe_webhooks_silent" => 0, "failed_payment_webhooks" => 0)
  end

  it "contains no buyer or attendee personal data" do
    json = summary.to_json
    expect(json).not_to match(/Zed|Buyerson|Pat Attendee|zed\.buyerson|pat\.attendee|6715550199|@example\.com/)
    expect(json).not_to include(online.reference, cash.reference)
    expect(json).not_to match(/pi_|evt_|re_test/)
  end

  it "writes nothing" do
    expect { summary }.not_to(change { [Order.count, Payment.count, RuntimeAlertState.count, AuditLog.count, WebhookEvent.count] })
    allow(Order).to receive(:excluding_test_payments).and_wrap_original do |original|
      expect { Order.connection.execute("UPDATE orders SET status = status") }.to raise_error(ActiveRecord::ReadOnlyError)
      original.call
    end
    summary
  end
end
