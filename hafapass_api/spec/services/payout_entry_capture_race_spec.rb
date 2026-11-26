# frozen_string_literal: true

require "rails_helper"
require "timeout"

# A2 payout entry (docs/design/never-fulfilled-captures.md §8.10.11,
# docs/LOCKING.md): this release's paid recording and its frozen custody
# determination are serialized with captures on the event row, in both
# commit orders. Paid first: a capture on the event waits for the recording,
# and the frozen row, written before it, never names it or counts it
# (no future disclosure). Capture first: the recording waits, then reads it.
# The row never changes afterwards. Real connections and commits;
# pg_blocking_pids proves each wait.
RSpec.describe "Paid recording serialized with captures (A2)", :non_transactional do
  self.use_transactional_tests = false

  RACE_DEADLINE = 20

  class RacePause
    def initialize
      @reached = Queue.new
      @go = Queue.new
    end

    def hit!(value = true)
      @reached << value
      @go.pop(timeout: RACE_DEADLINE) || raise("pause never released")
    end

    def reached = @reached.pop(timeout: RACE_DEADLINE) || raise("pause never reached")
    def release! = @go << true
  end

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

  let(:admin) { create(:user, :admin) }
  let(:profile) { create(:organizer_profile, :verified) }
  let(:organization) { profile.organization }
  let(:event) { create(:event, :completed, organization: organization, organizer_profile: profile) }

  before do
    clean_test_data
    allow(PayoutGateway).to receive(:submit) do |payout|
      PayoutGateway::Result.new(provider_payout_id: "manual_po_#{payout.id}", status: :processing)
    end
    allow(Sentry).to receive(:capture_message)
    allow(Sentry).to receive(:capture_exception)
    approved_bank_account!(organization, actor: profile.user, admin: admin)
  end

  after { clean_test_data }

  def live!(payment)
    Payment.where(id: payment.id).update_all(provider_environment: "live", provider_payment_id: "pi_live_#{SecureRandom.hex(4)}")
    payment.reload
  end

  # A funded live Stripe sale, a submitted payout on its version, and a
  # second order on the same event still waiting for its capture.
  def setup_event
    order, _item, a = record_card_sale!(event, ticket_type: create(:ticket_type, event: event, price_cents: 2000),
      quantity: 5, processing_fee_cents: 100)
    order.update!(fulfilled_by_payment_id: a.id)
    live!(a)
    payout = PayoutCreator.call(settlement: Settlements::Finalizer.call(event: event, actor: admin), actor: admin,
      idempotency_key: "race-#{SecureRandom.hex(3)}", amount_cents: 2000)
    later = create(:order, :pending, event: event, total_cents: 1200, subtotal_cents: 1200, service_fee_cents: 0)
    create(:order_item, order: later, unit_price_cents: 1200, quantity: 1, subtotal_cents: 1200,
      organizer_proceeds_cents: 1200, fee_cents: 0)
    c = live!(create(:payment, order: later, amount_cents: 1200, status: :pending))
    [a, payout, later, c]
  end

  def worker(&work)
    pid = Queue.new
    result = Queue.new
    thread = Thread.new do
      ActiveRecord::Base.connection_pool.with_connection(prevent_permanent_checkout: true) do |connection|
        connection.execute("SET lock_timeout = '15s'")
        pid << connection.select_value("SELECT pg_backend_pid()")
        begin
          result << work.call
        ensure
          connection.execute("RESET lock_timeout")
        end
      end
    rescue StandardError => error
      result << error
    end
    [thread, pid.pop(timeout: RACE_DEADLINE) || raise("worker never started"), result]
  end

  def wait_until_blocked(pid)
    Timeout.timeout(RACE_DEADLINE) do
      sleep 0.02 until ActiveRecord::Base.connection.select_value("SELECT cardinality(pg_blocking_pids(#{pid.to_i}))").to_i.positive?
    end
  end

  def outcome(thread, result)
    thread.join(RACE_DEADLINE) || raise("worker never finished")
    result.pop(timeout: 1)
  end

  # The lifecycle's capture locks: event context, order, payment.
  def capture(order_id, payment_id, pause = nil)
    Order.transaction do
      order = Order.find(order_id)
      Passes::Locking.lock_events_for_order!(order)
      order.lock!
      Payment.find(payment_id).lock!.update!(status: :succeeded, succeeded_at: Time.current)
      pause&.hit!
    end
    Payment.find(payment_id).capture_recorded_at
  end

  def record_paid(payout_id)
    PayoutReconciler.call(payout: Payout.find(payout_id), actor: User.find(admin.id), status: "paid",
      provider_payout_id: "bank-race-#{payout_id}",
      evidence: { reference: "Bank transfer record", reason: "Transfer confirmed by the bank",
        confirmed_at: Time.current.iso8601(6), approved_tax_payee_confirmed: true })
  end

  it "paid first: the capture waits, and the frozen determination never names or counts it" do
    a, payout, later, c = setup_event
    pause = RacePause.new
    allow(PayoutCustody).to receive(:record!).and_wrap_original do |original, *args, **options|
      original.call(*args, **options).tap { pause.hit! }
    end

    paid, = worker { record_paid(payout.id) }
    pause.reached
    captured, capture_pid, capture_result = worker { capture(later.id, c.id) }
    wait_until_blocked(capture_pid)
    pause.release!
    expect(outcome(paid, Queue.new.tap { |queue| queue << :paid })).to eq(:paid)
    captured_at = outcome(captured, capture_result)

    determination = payout.reload.custody_determination
    expect(payout).to be_status_paid
    expect(determination).to have_attributes(determination: "stripe_custody", qualifying_payment_ids: [a.id])
    expect(determination.determined_at).to be < captured_at
    expect(Time.iso8601(determination.evidence["conservative_bound_at"])).to be < captured_at
    frozen = determination.attributes
    # A later classification of the new capture does not rewrite it.
    later.update_columns(status: Order.statuses[:expired])
    classify_order_scope!(later.reload, c.reload)
    expect(PayoutCustodyDetermination.find_by!(payout_id: payout.id).attributes).to eq(frozen)
  end

  it "capture first: the paid recording waits for the capture and reads it in a fresh snapshot" do
    a, payout, later, c = setup_event
    pause = RacePause.new
    captured, = worker { capture(later.id, c.id, pause) }
    pause.reached
    paid, paid_pid, paid_result = worker { record_paid(payout.id) }
    wait_until_blocked(paid_pid)
    pause.release!
    captured.join(RACE_DEADLINE) || raise("capture never finished")
    expect(outcome(paid, paid_result)).to be_a(Payout)

    captured_at = c.reload.capture_recorded_at
    determination = payout.reload.custody_determination
    expect(determination).to have_attributes(determination: "stripe_custody", qualifying_payment_ids: [a.id])
    expect(Time.iso8601(determination.evidence["conservative_bound_at"])).to be > captured_at
  end
end
