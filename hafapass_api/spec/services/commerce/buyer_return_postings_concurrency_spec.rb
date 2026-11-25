# frozen_string_literal: true

require "rails_helper"
require "ostruct"

# Return postings under real lock contention (docs/design/never-fulfilled-
# captures.md §5.2, A1 tranche 3). A holder keeps the first contested row
# until every worker is blocked (pg_blocking_pids), then commits; the workers
# run the real writers. No sleep is an assertion.
RSpec.describe "Buyer return posting races", :non_transactional do
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
    allow(EmailService).to receive(:send_refund_notification_async)
    allow(StripeProcessingFees).to receive(:require_adjustment_review!)
    allow(StripeProcessingFees).to receive(:request!)
  end

  after { clean_test_data }

  # Holds `sql` until every worker is blocked behind something, then commits.
  def race(sql, workers)
    holding = Queue.new
    pids = Queue.new
    results = Queue.new
    holder = Thread.new do
      ActiveRecord::Base.connection_pool.with_connection(prevent_permanent_checkout: true) do |connection|
        connection.transaction do
          connection.execute("SET LOCAL lock_timeout = '#{lock_timeout}'")
          connection.select_value(sql)
          workers.size.times { holding << true }
          worker_pids = Array.new(workers.size) { pids.pop(timeout: deadline_seconds) || raise("worker never started") }
          deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + deadline_seconds
          until worker_pids.all? { |pid| connection.select_value("SELECT cardinality(pg_blocking_pids(#{pid.to_i}))").to_i.positive? }
            raise "workers never blocked" if Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline

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
          holding.pop(timeout: deadline_seconds) || raise("holder never locked")
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

  it "a provider refund and a dispute loss finishing together post once each, in one sequence, without deadlock" do
    order, payment, capture = classified_capture(items: [[1200, 160, 0, 0]])
    stripe_webhook!("charge.dispute.created", dispute_object(payment, "dp_race"))

    outcome = race("SELECT id FROM organizations WHERE id = #{order.event.organization.id.to_i} FOR UPDATE", [
      -> { ingest_provider_refund!(Payment.find(payment.id), 500, id: "re_race") && :refunded },
      -> { stripe_webhook!("charge.dispute.closed", dispute_object(payment, "dp_race", status: "lost")) && :lost }
    ])

    expect(outcome).to eq(holder: :committed, 0 => :refunded, 1 => :lost)
    postings = capture.buyer_return_postings.in_sequence.to_a
    expect(postings.map(&:sequence)).to eq([1, 2])
    expect(postings.sum(&:applied_cents)).to eq(1360)
    expect(postings.sum(&:excess_cents)).to eq(500)
    expect(postings.map(&:kind)).to contain_exactly("refund", "dispute_loss")
  end

  it "a late capture classified while its dispute loss commits posts the loss exactly once" do
    event = create(:event, :published)
    ticket_type = create(:ticket_type, event: event, price_cents: 1200, quantity_available: 10, quantity_sold: 0)
    allow(StripeService).to receive(:create_payment_intent).and_return(OpenStruct.new(id: "pi_race_loss",
      client_secret: "pi_race_loss_secret", allowed_payment_method_types: ["card"], payment_method_types: ["card"]))
    result = Commerce::OrderCreator.call(event: event, line_items: [{ ticket_type_id: ticket_type.id, quantity: 1 }],
      buyer_email: "buyer@example.com", buyer_name: "Buyer")
    Commerce::OrderLifecycle.cancel!(result.order)
    payment = result.payment.reload
    stripe_webhook!("charge.dispute.created", dispute_object(payment, "dp_race_loss"))
    receipt = WebhookEvent.create!(provider: "stripe", provider_event_id: "evt_race_capture", event_type: "payment_intent.succeeded",
      payload: { "id" => "evt_race_capture", "type" => "payment_intent.succeeded",
        "data" => { "object" => { "id" => payment.provider_payment_id, "amount_received" => payment.amount_cents,
          "currency" => "usd", "status" => "succeeded" } } })

    outcome = race("SELECT id FROM orders WHERE id = #{result.order.id.to_i} FOR UPDATE", [
      lambda do
        Commerce::OrderLifecycle.complete!(Order.find(result.order.id), payment: Payment.find(payment.id),
          webhook_event: WebhookEvent.find(receipt.id), provider_amount_cents: payment.amount_cents,
          provider_currency: "usd", late_completion: true)
      end,
      -> { stripe_webhook!("charge.dispute.closed", dispute_object(payment, "dp_race_loss", status: "lost")) && :lost }
    ])

    expect(outcome.values).to all(satisfy { |value| !value.is_a?(Exception) })
    capture = UnfulfilledCapture.find_by!(payment_id: payment.id)
    posting = capture.buyer_return_postings.sole
    expect(posting).to have_attributes(kind: "dispute_loss", source: Dispute.find_by!(provider_dispute_id: "dp_race_loss"),
      applied_cents: payment.amount_cents, recognized_at: [posting.recorded_at, capture.capture_recorded_at].max)
    expect(Commerce::BuyerReturnLedger.for(capture).owed_cents).to eq(0)
  end
end
