require "rails_helper"
require "timeout"

RSpec.describe "Commerce concurrency", :non_transactional do
  self.use_transactional_tests = false

  before do
    raise "Concurrency specs must only run in test" unless Rails.env.test?

    clean_test_data
    allow(StripeService).to receive(:payment_enabled?).and_return(true)
    allow(StripeService).to receive(:create_payment_intent) do |order, idempotency_key:|
      OpenStruct.new(id: "pi_concurrent_#{order.id}", client_secret: "#{idempotency_key}_secret")
    end
    allow(EmailService).to receive(:send_refund_notification_async)
  end

  after do
    clean_test_data
  end

  it "allows exactly one checkout to hold the final ticket" do
    event = create(:event, :published, starts_at: 5.days.from_now)
    ticket_type = create(:ticket_type, event: event, quantity_available: 1, max_per_order: 1)

    outcomes = run_concurrently(2) do |index|
      Commerce::OrderCreator.call(
        event: Event.find(event.id),
        line_items: [{ ticket_type_id: ticket_type.id, quantity: 1 }],
        buyer_email: "buyer#{index}@example.com",
        buyer_name: "Buyer #{index}"
      )
    end

    expect(outcomes.count { |outcome| outcome.is_a?(Commerce::OrderCreator::Result) }).to eq(1)
    expect(outcomes.count { |outcome| outcome.is_a?(Commerce::OrderCreator::CheckoutError) }).to eq(1)
    expect(InventoryHold.current.sum(:quantity)).to eq(1)
    expect(ticket_type.reload.available_quantity).to eq(0)
  end

  it "enforces shared event capacity across concurrent ticket types" do
    event = create(:event, :published, starts_at: 5.days.from_now, max_capacity: 1)
    types = [
      create(:ticket_type, event: event, quantity_available: 5, max_per_order: 5),
      create(:ticket_type, event: event, quantity_available: 5, max_per_order: 5)
    ]

    outcomes = run_concurrently(2) do |index|
      Commerce::OrderCreator.call(
        event: Event.find(event.id),
        line_items: [{ ticket_type_id: types[index].id, quantity: 1 }],
        buyer_email: "capacity#{index}@example.com",
        buyer_name: "Capacity #{index}"
      )
    end

    expect(outcomes.count { |outcome| outcome.is_a?(Commerce::OrderCreator::Result) }).to eq(1)
    expect(InventoryHold.current.sum(:quantity)).to eq(1)
  end

  it "serializes competing refund requests so committed value cannot exceed the charge" do
    event = create(:event, :published, starts_at: 5.days.from_now)
    ticket_type = create(:ticket_type, event: event, quantity_sold: 1)
    order = create(:order, event: event, subtotal_cents: 5000, service_fee_cents: 250, total_cents: 5250)
    create(
      :order_item,
      order: order,
      ticket_type: ticket_type,
      unit_price_cents: 5000,
      subtotal_cents: 5000,
      fee_cents: 250,
      organizer_proceeds_cents: 5000
    )
    create(:payment, :succeeded, order: order, amount_cents: 5250, provider_payment_id: "sim_pi_concurrent_refund")

    outcomes = run_concurrently(2) do |index|
      Commerce::RefundCreator.call(
        order: Order.find(order.id),
        amount_cents: 4000,
        idempotency_key: "concurrent-refund-#{index}"
      )
    end

    expect(outcomes.count { |outcome| outcome.is_a?(Refund) }).to eq(1)
    expect(outcomes.count { |outcome| outcome.is_a?(Commerce::RefundCreator::RefundError) }).to eq(1)
    expect(order.refunds.succeeded.sum(:amount_cents)).to eq(4000)
    expect(order.reload.refundable_cents).to eq(1250)
  end

  def run_concurrently(count)
    ready = Queue.new
    start = Queue.new
    results = Queue.new
    threads = count.times.map do |index|
      Thread.new do
        ActiveRecord::Base.connection_pool.with_connection do
          ready << true
          start.pop
          results << yield(index)
        rescue StandardError => e
          results << e
        end
      end
    end
    Timeout.timeout(15) do
      count.times { ready.pop }
      count.times { start << true }
      threads.each(&:join)
      count.times.map { results.pop }
    end
  ensure
    threads&.each { |thread| thread.kill if thread.alive? }
  end

  def clean_test_data
    connection = ActiveRecord::Base.connection
    connection.execute("SET lock_timeout = '5s'")
    connection.execute(<<~SQL)
      TRUNCATE TABLE users, organizer_profiles, events, site_settings, webhook_events
      RESTART IDENTITY CASCADE
    SQL
  ensure
    connection&.execute("SET lock_timeout = 0")
  end
end
