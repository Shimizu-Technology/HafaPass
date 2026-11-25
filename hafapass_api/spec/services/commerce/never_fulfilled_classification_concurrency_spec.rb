# frozen_string_literal: true

require "rails_helper"
require "ostruct"

# Lifecycle classification writers under real lock contention
# (docs/design/never-fulfilled-captures.md §4.3, A1 tranche 2). Three
# PostgreSQL connections: a holder keeps the order row FOR UPDATE until both
# workers are blocked (pg_blocking_pids), then commits. The workers run the
# real OrderLifecycle.complete! with stored signed-webhook receipts, so only
# the documented event -> order -> payment prefix serializes them. No sleep is
# an assertion.
RSpec.describe "Never-fulfilled classification races", :non_transactional do
  self.use_transactional_tests = false

  def lock_timeout = "8s"
  def deadline_seconds = 20

  def clean_test_data
    unless Rails.env.test? && ActiveRecord::Base.connection_db_config.database.end_with?("_test")
      raise "Isolated test database required"
    end

    ActiveRecord::Base.connection.execute(<<~SQL)
      TRUNCATE TABLE audit_logs, audit_write_failures, organizations, users, organizer_profiles, events, site_settings,
        webhook_events, checkout_attempts
      RESTART IDENTITY CASCADE
    SQL
  end

  before do
    clean_test_data
    SiteSetting.instance.update!(payment_mode: "test")
    allow(StripeService).to receive(:payment_enabled?).and_return(true)
    allow(StripeService).to receive(:card_only_intent?).and_return(true)
    allow(StripeService).to receive(:cancel_payment_intent)
    allow(EmailService).to receive(:send_order_confirmation_async)
  end

  after { clean_test_data }

  let(:event) { create(:event, :published) }
  let(:ticket_type) { create(:ticket_type, event: event, price_cents: 1200, quantity_available: 10, quantity_sold: 0) }

  def checkout(intent_id)
    allow(StripeService).to receive(:create_payment_intent).and_return(OpenStruct.new(id: intent_id,
      client_secret: "#{intent_id}_secret", allowed_payment_method_types: ["card"], payment_method_types: ["card"]))
    Commerce::OrderCreator.call(event: event, line_items: [{ ticket_type_id: ticket_type.id, quantity: 1 }],
      buyer_email: "buyer@example.com", buyer_name: "Buyer")
  end

  def receipt_for(payment, event_id)
    WebhookEvent.create!(provider: "stripe", provider_event_id: event_id, event_type: "payment_intent.succeeded",
      payload: { "id" => event_id, "type" => "payment_intent.succeeded",
        "data" => { "object" => { "id" => payment.provider_payment_id, "amount_received" => payment.amount_cents,
          "currency" => "usd", "status" => "succeeded" } } })
  end

  def complete_in_thread(order_id, payment_id, receipt_id)
    order = Order.find(order_id)
    payment = Payment.find(payment_id)
    Commerce::OrderLifecycle.complete!(order, payment: payment, webhook_event: WebhookEvent.find(receipt_id),
      provider_amount_cents: payment.amount_cents, provider_currency: "usd", late_completion: true)
  end

  # Holds the order row until both workers are blocked, then commits.
  def race(order, workers)
    holding = Queue.new
    pids = Queue.new
    results = Queue.new
    holder = Thread.new do
      ActiveRecord::Base.connection_pool.with_connection(prevent_permanent_checkout: true) do |connection|
        connection.transaction do
          connection.execute("SET LOCAL lock_timeout = '#{lock_timeout}'")
          connection.select_value("SELECT id FROM orders WHERE id = #{order.id.to_i} FOR UPDATE")
          workers.size.times { holding << true }
          worker_pids = Array.new(workers.size) { pids.pop(timeout: deadline_seconds) || raise("worker never started") }
          deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + deadline_seconds
          until worker_pids.all? { |pid| connection.select_value("SELECT cardinality(pg_blocking_pids(#{pid.to_i}))").to_i.positive? }
            raise "workers never blocked behind the order" if Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline

            sleep 0.02
          end
        end
      end
      results << [:holder, :committed]
    rescue StandardError => error
      results << [:holder, error]
    end
    threads = workers.each_with_index.map do |work, index|
      Thread.new do
        ActiveRecord::Base.connection_pool.with_connection(prevent_permanent_checkout: true) do |connection|
          holding.pop(timeout: deadline_seconds) || raise("holder never locked the order")
          connection.execute("SET lock_timeout = '#{lock_timeout}'")
          pids << connection.select_value("SELECT pg_backend_pid()")
          begin
            results << [index, work.call]
          ensure
            connection.execute("RESET lock_timeout")
          end
        end
      rescue StandardError => error
        results << [index, error]
      end
    end
    ([holder] + threads).each { |thread| thread.join(deadline_seconds * 2) || thread.kill }
    Array.new(results.size) { results.pop }.to_h
  end

  it "two verified payments succeeding together on one pending order: one fulfils, the other is payment scope" do
    result = checkout("pi_race_a")
    order = result.order
    payment_a = result.payment
    payment_b = order.payments.create!(provider: "stripe", provider_environment: "test",
      provider_platform_account_id: payment_a.provider_platform_account_id, provider_payment_id: "pi_race_b",
      idempotency_key: "race:second:#{order.id}", amount_cents: order.total_cents, currency: "usd", status: :pending)
    receipt_a = receipt_for(payment_a, "evt_race_a")
    receipt_b = receipt_for(payment_b, "evt_race_b")

    outcome = race(order, [
      -> { complete_in_thread(order.id, payment_a.id, receipt_a.id) },
      -> { complete_in_thread(order.id, payment_b.id, receipt_b.id) }
    ])

    expect(outcome[:holder]).to eq(:committed)
    expect([outcome[0], outcome[1]]).to contain_exactly(:completed, :unchanged)
    order.reload
    winner = outcome[0] == :completed ? payment_a : payment_b
    loser = winner == payment_a ? payment_b : payment_a
    expect(order).to be_completed
    expect(order.fulfilled_by_payment_id).to eq(winner.id)
    expect(order.never_fulfilled_at).to be_nil
    expect(order.tickets.where.not(status: :cancelled).count).to eq(1)
    expect(ticket_type.reload.quantity_sold).to eq(1)
    expect(UnfulfilledCapture.sole).to have_attributes(payment_id: loser.id, capture_scope: "payment",
      code: "unfulfilled_second_capture")
    expect(ReconciliationException.pluck(:payment_id, :code)).to eq([[loser.id, "unfulfilled_second_capture"]])
  end

  it "duplicate deliveries for one released payment racing each other write one classification and one exception" do
    result = checkout("pi_race_dup")
    Commerce::OrderLifecycle.cancel!(result.order)
    receipts = [receipt_for(result.payment, "evt_race_dup_1"), receipt_for(result.payment, "evt_race_dup_2")]

    outcome = race(result.order, receipts.map { |receipt| -> { complete_in_thread(result.order.id, result.payment.id, receipt.id) } })

    expect(outcome.values).to all(satisfy { |value| !value.is_a?(Exception) })
    expect(UnfulfilledCapture.where(payment_id: result.payment.id).count).to eq(1)
    capture = UnfulfilledCapture.sole
    expect(receipts.map(&:id)).to include(capture.provenance_evidence["webhook_event_id"])
    expect(ReconciliationException.where(payment_id: result.payment.id).pluck(:code))
      .to eq(["late_payment_success_after_inventory_release"])
    expect(result.order.reload).to be_cancelled
    expect(result.order.never_fulfilled_at).to eq(capture.created_at)
  end
end
