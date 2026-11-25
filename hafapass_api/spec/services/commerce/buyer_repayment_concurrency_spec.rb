# frozen_string_literal: true

require "rails_helper"
require "ostruct"

# Repayment operations under real lock contention (docs/design/never-
# fulfilled-captures.md §6.3, §10.3 M-08). A holder keeps the organization
# row until every worker is blocked behind it (pg_blocking_pids), then
# commits; the workers run the real entry points. Each provider POST is
# counted. No sleep is an assertion.
RSpec.describe "Buyer repayment races", :non_transactional do
  self.use_transactional_tests = false

  def lock_timeout = "8s"
  def deadline_seconds = 20

  let(:posts) { Queue.new }

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
    allow(StripeService).to receive(:refund_payment) do |intent_id, amount_cents:, idempotency_key:, **|
      posts << [amount_cents, idempotency_key]
      OpenStruct.new(id: "re_race_#{SecureRandom.hex(3)}", status: "succeeded", amount: amount_cents, currency: "usd",
        payment_intent: intent_id, metadata: { "hafapass_refund_key" => idempotency_key })
    end
    allow(StripeService).to receive(:find_refund).and_return(nil)
    allow(EmailService).to receive(:send_refund_notification_async)
    allow(StripeProcessingFees).to receive(:require_adjustment_review!)
    allow(Sentry).to receive(:capture_message)
    # A1-R1 and A1-R2 differ only in this constant; a thread names its release.
    allow(Commerce::BuyerRepayment).to receive(:submitter_active?) { Thread.current[:release] != :r1 }
  end

  after { clean_test_data }

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
    threads = workers.each_with_index.map do |(release, work), index|
      Thread.new do
        Thread.current[:release] = release
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

  def late_capture
    order, payment, capture = classified_capture(items: [[1200, 160, 0, 0]])
    ReconciliationException.create!(order: order, payment: payment, code: "late_payment_success_after_hold_expiry")
    [order, payment, capture]
  end

  def lock_organization(order)
    "SELECT id FROM organizations WHERE id = #{order.event.organization.id.to_i} FOR UPDATE"
  end

  def attempt(payment_id)
    Commerce::LateCaptureRefund.call(payment: Payment.find(payment_id)).status.to_sym
  rescue Commerce::BuyerRepayment::Waiting => e
    e.reason.to_sym
  end

  it "two A1-R2 workers reserving together send exactly one operation" do
    order, payment, capture = late_capture

    outcome = race(lock_organization(order), [[:r2, -> { attempt(payment.id) }], [:r2, -> { attempt(payment.id) }]])

    expect(outcome[:holder]).to eq(:committed)
    expect(outcome.values_at(0, 1)).to contain_exactly(:succeeded, :refund_unknown).or contain_exactly(:succeeded, :succeeded)
    expect(Array.new(posts.size) { posts.pop }).to eq([[1360, "late-capture:payment:#{payment.id}:op:1"]])
    expect(capture.repayment_operations.pluck(:sequence, :state, :submission_count)).to eq([[1, "succeeded", 1]])
  end

  it "an A1-R1 worker racing an A1-R2 worker never submits; R2 submits once" do
    order, payment, capture = late_capture

    outcome = race(lock_organization(order), [[:r1, -> { attempt(payment.id) }], [:r2, -> { attempt(payment.id) }]])

    expect(outcome[:holder]).to eq(:committed)
    expect(outcome[0]).to eq(:repayment_inactive).or eq(:refund_unknown).or eq(:nothing_owed)
    expect(outcome[1]).to eq(:succeeded)
    expect(Array.new(posts.size) { posts.pop }).to eq([[1360, "late-capture:payment:#{payment.id}:op:1"]])
    expect(capture.repayment_operations.pluck(:state, :submission_count)).to eq([["succeeded", 1]])
  end

  it "an old 7bcd97c2 worker racing an A1-R2 worker at reservation sends nothing" do
    order, payment, capture = late_capture
    legacy = Legacy7bcd97c2.late_capture_refund

    outcome = race(lock_organization(order), [
      [:old, lambda do
        legacy.call(payment: Payment.find(payment.id))
        :sent
      rescue ActiveRecord::StatementInvalid, Legacy7bcd97c2::Commerce::RefundCreator::RefundError
        :refused
      end],
      [:r2, -> { attempt(payment.id) }]
    ])

    expect(outcome).to include(holder: :committed, 0 => :refused, 1 => :succeeded)
    expect(Array.new(posts.size) { posts.pop }).to eq([[1360, "late-capture:payment:#{payment.id}:op:1"]])
    expect(capture.repayment_operations.count).to eq(1)
    expect(payment.refunds.count).to eq(1)
  end

  it "two A1-R2 workers at the last gate of one reserved operation produce one sender" do
    order, payment, capture = late_capture
    Order.transaction do
      order.event.organization.lock!("FOR NO KEY UPDATE")
      order.event.lock!
      order.lock!
      Commerce::BuyerRepayment.reserve!(order: order, payment: payment, source: "automatic")
    end

    outcome = race(lock_organization(order), [[:r2, -> { attempt(payment.id) }], [:r2, -> { attempt(payment.id) }]])

    expect(outcome[:holder]).to eq(:committed)
    expect(Array.new(posts.size) { posts.pop }).to eq([[1360, "late-capture:payment:#{payment.id}:op:1"]])
    expect(capture.repayment_operations.pluck(:state, :submission_count)).to eq([["succeeded", 1]])
  end
end
