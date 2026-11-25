# frozen_string_literal: true

require "rails_helper"

# Order-row serialization between ticket issuance and order-scope
# classification (docs/design/never-fulfilled-captures.md §4.2, X-08…X-10).
# Two PostgreSQL connections, committed fixtures, latches, a short
# lock_timeout, and contention proven with pg_blocking_pids. No sleep is an
# assertion. Both sides use raw SQL so only the triggers serialize them.
RSpec.describe "Never-fulfilled classification and ticket issuance races", :non_transactional do
  self.use_transactional_tests = false

  def lock_timeout = "8s"
  def deadline_seconds = 15

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

  before { clean_test_data }
  after { clean_test_data }

  let!(:order) { create(:order, status: :expired, completed_at: nil, subtotal_cents: 1200, service_fee_cents: 160, total_cents: 1360) }
  let!(:payment) { create(:payment, order: order, status: :succeeded, succeeded_at: Time.current) }
  let!(:ticket_type) { create(:ticket_type, event: order.event) }

  def insert_ticket_sql(status: 0)
    <<~SQL.squish
      INSERT INTO tickets (order_id, ticket_type_id, event_id, status, qr_code, created_at, updated_at)
      VALUES (#{order.id}, #{ticket_type.id}, #{order.event_id}, #{status}, '#{SecureRandom.uuid}', now(), now())
    SQL
  end

  def classify_sql
    <<~SQL.squish
      INSERT INTO never_fulfilled_captures (order_id, payment_id, capture_scope, code, captured_cents, currency,
        proceeds_cents, fee_cents, organizer_fee_cents, tax_cents, processing_bearer, dispute_fee_bearer,
        allocation_policy, policy_version, provenance)
      VALUES (#{order.id}, #{payment.id}, 'order', 'late_payment_success_after_hold_expiry', 1360, '#{payment.currency}',
        1200, 160, 0, 0, 'platform', 'platform', 'item_record', 'nfc-v2.1', 'lifecycle')
    SQL
  end

  # The holder runs `held` and keeps its transaction open until the contender
  # is blocked behind it, then commits. Returns { holder:, contender: }.
  def race(held:, contended:)
    holding = Queue.new
    contender_pid = Queue.new
    results = Queue.new
    holder = Thread.new do
      ActiveRecord::Base.connection_pool.with_connection(prevent_permanent_checkout: true) do |connection|
        connection.transaction do
          connection.execute("SET LOCAL lock_timeout = '#{lock_timeout}'")
          connection.execute(held)
          holding << true
          pid = contender_pid.pop(timeout: deadline_seconds) || raise("contender never started")
          deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + deadline_seconds
          until connection.select_value("SELECT cardinality(pg_blocking_pids(#{pid.to_i}))").to_i.positive?
            raise "contender never blocked on the order" if Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline

            sleep 0.02
          end
        end
      end
      results << [:holder, :committed]
    rescue StandardError => error
      results << [:holder, error]
    end
    contender = Thread.new do
      ActiveRecord::Base.connection_pool.with_connection(prevent_permanent_checkout: true) do |connection|
        contender_pid << connection.select_value("SELECT pg_backend_pid()")
        holding.pop(timeout: deadline_seconds) || raise("holder never acquired its lock")
        connection.transaction do
          connection.execute("SET LOCAL lock_timeout = '#{lock_timeout}'")
          connection.execute(contended)
        end
      end
      results << [:contender, :committed]
    rescue StandardError => error
      results << [:contender, error]
    end
    [holder, contender].each { |thread| thread.join(deadline_seconds * 2) || thread.kill }
    Array.new(results.size) { results.pop }.to_h
  end

  it "X-08: a ticket insert that holds the order first makes the waiting classification refuse" do
    outcome = race(held: insert_ticket_sql, contended: classify_sql)

    expect(outcome[:holder]).to eq(:committed)
    expect(outcome[:contender]).to be_a(ActiveRecord::StatementInvalid)
    expect(outcome[:contender].message).to match(/active tickets/)
    expect(UnfulfilledCapture.where(order_id: order.id)).to be_empty
    expect(order.reload.never_fulfilled_at).to be_nil
    expect(Ticket.where(order_id: order.id).where.not(status: :cancelled).count).to eq(1)
  end

  it "X-09: a classification that holds the order first makes the waiting ticket insert refuse" do
    outcome = race(held: classify_sql, contended: insert_ticket_sql)

    expect(outcome[:holder]).to eq(:committed)
    expect(outcome[:contender]).to be_a(ActiveRecord::StatementInvalid)
    expect(outcome[:contender].message).to match(/never-fulfilled order/)
    expect(order.reload.never_fulfilled_at).to be_present
    expect(Ticket.where(order_id: order.id)).to be_empty
  end

  it "X-10: a reactivation that skips the order prefix fails at once instead of waiting while holding the ticket" do
    cancelled = create(:ticket, :cancelled, order: order, ticket_type: ticket_type)
    holding = Queue.new
    contender_done = Queue.new
    holder = Thread.new do
      ActiveRecord::Base.connection_pool.with_connection(prevent_permanent_checkout: true) do |connection|
        connection.transaction do
          connection.select_value("SELECT id FROM orders WHERE id = #{order.id} FOR UPDATE")
          holding << true
          contender_done.pop(timeout: deadline_seconds) || raise("contender never finished")
          raise ActiveRecord::Rollback
        end
      end
    end
    contender_result = nil
    contender = Thread.new do
      ActiveRecord::Base.connection_pool.with_connection(prevent_permanent_checkout: true) do |connection|
        holding.pop(timeout: deadline_seconds) || raise("holder never locked the order")
        connection.transaction do
          connection.execute("SET LOCAL lock_timeout = '#{lock_timeout}'")
          connection.execute("UPDATE tickets SET status = 0 WHERE id = #{cancelled.id}")
        end
        contender_result = :committed
      rescue StandardError => error
        contender_result = error
      ensure
        contender_done << true
      end
    end
    [contender, holder].each { |thread| thread.join(deadline_seconds * 2) || thread.kill }

    # It finished while the holder still had the order: no wait, no ticket → order cycle.
    expect(contender_result).to be_a(ActiveRecord::StatementInvalid)
    expect(contender_result.message).to match(/Lock the order before reactivating/)
    expect(cancelled.reload).to be_cancelled
  end
end
