# frozen_string_literal: true

require "rails_helper"
require "timeout"

# CodeRabbit review of 758485ae, concurrency, with real connections and
# commits; pg_blocking_pids proves each wait (docs/LOCKING.md):
#   4705527070 a custody determination's insert and a change of its payout's
#              settlement version serialize on the payout row in both
#              transaction orders, so a determination never names a version
#              the payout no longer has;
#   4705527020 two payouts cannot both commit a return proof for one bank
#              return reference: the second waits on the first and is refused.
RSpec.describe "Payout custody and return proof races (A2)", :non_transactional do
  self.use_transactional_tests = false

  RACE_DEADLINE = 20

  class CustodyRacePause
    def initialize
      @reached = Queue.new
      @go = Queue.new
    end

    def hit!
      @reached << true
      @go.pop(timeout: RACE_DEADLINE) || raise("pause never released")
    end

    def reached = @reached.pop(timeout: RACE_DEADLINE) || raise("pause never reached")
    def release! = @go << true
  end

  # CodeRabbit 4706251787: every worker an example started has exited, and
  # returned its connection, before the cleanup's TRUNCATE runs, even when
  # an expectation failed first. Each pause is released (a waiting worker
  # then finishes or hits its lock_timeout), then each thread is joined
  # without a deadline: a deadline does not stop a worker, so cleanup would
  # still race it. Workers are bounded by their own pause and lock timeouts.
  def pause
    CustodyRacePause.new.tap { |created| @pauses << created }
  end

  def join_workers!
    @pauses.each(&:release!)
    @workers.each(&:join)
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

  before do
    @workers = []
    @pauses = []
    clean_test_data
    allow(PayoutGateway).to receive(:submit) do |payout|
      PayoutGateway::Result.new(provider_payout_id: "manual_po_#{payout.id}", status: :processing)
    end
    allow(StripeService).to receive(:verify_payment_context!)
    allow(Sentry).to receive(:capture_message)
    allow(Sentry).to receive(:capture_exception)
  end

  after do
    join_workers!
    clean_test_data
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
    @workers << thread
    [thread, pid.pop(timeout: RACE_DEADLINE) || raise("worker never started"), result]
  end

  # The waiter's backend is blocked by the holder's (not merely slow).
  def wait_until_blocked(waiter, holder)
    Timeout.timeout(RACE_DEADLINE) do
      sleep 0.02 until ActiveRecord::Base.connection.select_value("SELECT pg_blocking_pids(#{waiter.to_i})")
        .to_s.delete("{}").split(",").map(&:to_i).include?(holder.to_i)
    end
  end

  def outcome(thread, result)
    thread.join(RACE_DEADLINE) || raise("worker never finished")
    result.pop(timeout: 1)
  end

  def funded_event!(name)
    profile = create(:organizer_profile, :verified)
    approved_bank_account!(profile.organization, actor: profile.user, admin: admin)
    event = create(:event, :completed, organization: profile.organization, organizer_profile: profile, title: name)
    record_card_sale!(event, ticket_type: create(:ticket_type, event: event, price_cents: 2000), quantity: 5)
    event
  end

  describe "custody determination and settlement version (4705527070)" do
    # A payout recorded paid before the A2 payout entry migration (history):
    # paid, no determination, and a second finalized version on its event.
    def historical_paid!
      event = funded_event!("Custody race")
      payout = PayoutCreator.call(settlement: Settlements::Finalizer.call(event: event, actor: admin), actor: admin,
        idempotency_key: "custody-race-#{SecureRandom.hex(3)}", amount_cents: 1000)
      connection = ActiveRecord::Base.connection
      begin
        connection.execute("ALTER TABLE payouts DISABLE TRIGGER payouts_require_custody")
        payout.update_columns(status: Payout.statuses[:paid], paid_at: 1.hour.ago, provider_payout_id: "BANK-HIST-#{payout.id}")
      ensure
        connection.execute("ALTER TABLE payouts ENABLE TRIGGER payouts_require_custody")
      end
      other = create(:settlement, event: event, organization: event.organization,
        version: event.settlements.maximum(:version).to_i + 1)
      [payout.reload, payout.settlement_id, other.id]
    end

    # The authorized history derivation's insert (no application lock).
    def derive!(payout_id, settlement_id, pause = nil)
      PayoutCustodyDetermination.transaction do
        FinancialIntegrity.with_evidence(:custody_derivation, payout_id) do
          PayoutCustodyDetermination.insert_all([{ payout_id: payout_id, settlement_id: settlement_id,
            determination: "ambiguous", basis: "derived_history", conservative_inclusion: true,
            evidence: { authorized_by: "FIN-7", published_baseline: { included: true, source: "bpt-export:2027-01" } } }],
            unique_by: :payout_id, record_timestamps: false)
        end
        pause&.hit!
      end
      :determined
    end

    # A direct writer moving the payout to another version.
    def move!(payout_id, settlement_id, pause = nil)
      Payout.transaction do
        Payout.where(id: payout_id).update_all(settlement_id: settlement_id)
        pause&.hit!
      end
      :moved
    end

    it "determination first: the version change waits for it, then sees it and is refused" do
      payout, funded, other = historical_paid!
      pause = self.pause
      derived, derive_pid, derive_result = worker { derive!(payout.id, funded, pause) }
      pause.reached
      moved, move_pid, move_result = worker { move!(payout.id, other) }
      wait_until_blocked(move_pid, derive_pid)
      pause.release!
      expect(outcome(derived, derive_result)).to eq(:determined)
      error = outcome(moved, move_result)
      expect(error).to be_a(ActiveRecord::StatementInvalid)
      expect(error.message).to include("settlement version is fixed once its custody is determined")
      expect(payout.reload.settlement_id).to eq(funded)
      expect(PayoutCustodyDetermination.find_by!(payout_id: payout.id).settlement_id).to eq(funded)
    end

    it "version change first: the determination waits for it, then reads the new version and is refused" do
      payout, funded, other = historical_paid!
      pause = self.pause
      moved, move_pid, move_result = worker { move!(payout.id, other, pause) }
      pause.reached
      derived, derive_pid, derive_result = worker { derive!(payout.id, funded) }
      wait_until_blocked(derive_pid, move_pid)
      pause.release!
      expect(outcome(moved, move_result)).to eq(:moved)
      error = outcome(derived, derive_result)
      expect(error).to be_a(ActiveRecord::StatementInvalid)
      expect(error.message).to include("must name its payout's own settlement version")
      expect(payout.reload.settlement_id).to eq(other)
      expect(PayoutCustodyDetermination.where(payout_id: payout.id)).to be_empty
    end
  end

  it "lets one bank return reference back one payout's proof when two organizations attach it at once (4705527020)" do
    paid = %w[A B].map do |name|
      event = funded_event!("Return race #{name}")
      payout = PayoutCreator.call(settlement: Settlements::Finalizer.call(event: event, actor: admin), actor: admin,
        idempotency_key: "return-race-#{name}", amount_cents: 1000)
      PayoutReconciler.call(payout: payout, actor: admin, status: "paid", provider_payout_id: "BANK-RACE-#{name}",
        evidence: { reference: "Bank transfer record", reason: "Transfer confirmed by the bank",
          confirmed_at: Time.current.iso8601(6), approved_tax_payee_confirmed: true })
      payout.reload
    end
    first, second = paid
    expect(first.organization_id).not_to eq(second.organization_id)
    pause = self.pause
    allow(PayoutReturnProof).to receive(:create!).and_wrap_original do |original, **attributes|
      original.call(**attributes).tap { |proof| pause.hit! if proof.payout_id == first.id }
    end
    reverse = lambda do |payout|
      PayoutReconciler.call(payout: Payout.find(payout.id), actor: User.find(admin.id), status: "reversed",
        provider_payout_id: payout.provider_payout_id,
        evidence: { reference: "Bank return statement", reason: "Bank returned the transfer",
          confirmed_at: Time.current.iso8601(6), return_reference: "RET-RACE-SHARED", returned_amount_cents: 1000,
          returned_at: Time.current.iso8601(6) })
    end

    winner, winner_pid, winner_result = worker { reverse.call(first) }
    pause.reached
    loser, loser_pid, loser_result = worker { reverse.call(second) }
    wait_until_blocked(loser_pid, winner_pid)
    pause.release!
    expect(outcome(winner, winner_result)).to be_a(Payout)
    error = outcome(loser, loser_result)
    expect(error).to be_a(PayoutReconciler::ReconciliationError)
    expect(error.message).to eq(PayoutReconciler::RETURN_REFERENCE_USED_MESSAGE)
    expect(PayoutReturnProof.pluck(:payout_id)).to eq([first.id])
    expect(first.reload).to be_status_reversed
    expect(second.reload).to have_attributes(status: "paid", provider_payout_id: "BANK-RACE-B")
    expect(AuditLog.where(auditable: second, action: "payout.reconciled").where("after_data->>'status' = 'reversed'")).to be_empty
  end
end
