# frozen_string_literal: true

require "rails_helper"

# Lock order of the payout paths against an order lifecycle step
# (docs/LOCKING.md). Commerce::OrderLifecycle completes, fails, cancels or
# expires an order holding the event FOR NO KEY UPDATE, then inserts audit rows
# whose organization foreign key takes FOR KEY SHARE. Every payout path that
# locks the organization and then the event must take the organization
# FOR NO KEY UPDATE (compatible with KEY SHARE), or the two deadlock. The
# reviews of PR #239 reproduced the deadlock for reserves (round 1) and for the
# finalizer, payout creation and hold release (round 2).
RSpec.describe "Payout lock order", :non_transactional do
  self.use_transactional_tests = false

  let(:admin) { create(:user, :admin) }
  let(:profile) { create(:organizer_profile, :verified) }
  let(:organization) { profile.organization }
  let(:event) { create(:event, :completed, organization: organization, organizer_profile: profile) }

  def clean_test_data
    unless Rails.env.test? && ActiveRecord::Base.connection_db_config.database.end_with?("_test")
      raise "Isolated test database required"
    end

    ActiveRecord::Base.connection.execute(<<~SQL)
      TRUNCATE TABLE audit_logs, audit_write_failures, organizations, users, organizer_profiles, events, site_settings, webhook_events, checkout_attempts
      RESTART IDENTITY CASCADE
    SQL
  end

  before do
    raise "Concurrency fixtures require test" unless Rails.env.test?

    clean_test_data
    allow(PayoutGateway).to receive(:submit) do |payout|
      PayoutGateway::Result.new(provider_payout_id: "manual_po_#{payout.id}", status: :processing)
    end
  end

  after do
    clean_test_data
    # Nothing from these races may stay checked out for later specs.
    expect(ActiveRecord::Base.connection_pool.stat[:busy]).to be <= 1
  end

  def sell!
    record_card_sale!(event, ticket_type: create(:ticket_type, event: event, price_cents: 2000), quantity: 5,
      processing_fee_cents: 100)
  end

  def expect_both_committed(outcome)
    expect(outcome.fetch(:holder)).to eq(:committed)
    expect(outcome.fetch(:worker)).not_to be_a(StandardError)
    outcome.fetch(:worker)
  end

  it "holds a reserve while an order lifecycle step holds the event and writes its audit" do
    sell!
    outcome = race_against_event_audit(event: event, organization: organization) do
      PayoutReserves.hold!(event: Event.find(event.id), actor: User.find(admin.id))
    end
    expect(expect_both_committed(outcome).amount_cents).to eq(-990)
  end

  it "finalizes a statement while an order lifecycle step holds the event and writes its audit" do
    sell!
    outcome = race_against_event_audit(event: event, organization: organization) do
      Settlements::Finalizer.call(event: Event.find(event.id), actor: User.find(admin.id))
    end
    expect(expect_both_committed(outcome)).to have_attributes(version: 1, payable_cents: 9900)
  end

  it "reserves a payout while an order lifecycle step holds the event and writes its audit" do
    sell!
    approved_bank_account!(organization, actor: profile.user, admin: admin)
    settlement = Settlements::Finalizer.call(event: event, actor: admin)
    outcome = race_against_event_audit(event: event, organization: organization) do
      PayoutCreator.call(settlement: Settlement.find(settlement.id), actor: User.find(admin.id), idempotency_key: "race-payout")
    end
    expect(expect_both_committed(outcome)).to have_attributes(amount_cents: 9900, status: "processing")
  end

  it "releases a held payout while an order lifecycle step holds the event and writes its audit" do
    sell!
    account = approved_bank_account!(organization, actor: profile.user, admin: admin)
    settlement = Settlements::Finalizer.call(event: event, actor: admin)
    payout = create(:payout, organization: organization, event: event, settlement: settlement, connected_account: account,
      amount_cents: 9900, status: :held, held_from_status: "pending")
    outcome = race_against_event_audit(event: event, organization: organization) do
      PayoutHoldRelease.call(payout: Payout.find(payout.id), actor: User.find(admin.id))
    end
    expect(expect_both_committed(outcome)).to be(true)
    expect(payout.reload.status).to eq("pending")
  end

  # The lighter organization lock must still serialize the money writers with
  # each other: two reserve requests, or a reserve and a payout reservation.
  def run_together(*jobs)
    ready = Queue.new
    start = Queue.new
    results = Queue.new
    threads = jobs.map do |job|
      Thread.new do
        ActiveRecord::Base.connection_pool.with_connection(prevent_permanent_checkout: true) do
          ready << true
          start.pop(timeout: 10)
          results << job.call
        end
      rescue StandardError => error
        results << error
      ensure
        ActiveRecord::Base.connection_pool.release_connection
      end
    end
    jobs.size.times { ready.pop(timeout: 10) }
    jobs.size.times { start << true }
    threads.each { |thread| thread.join(20) }
    Array.new(jobs.size) { results.pop(timeout: 1) }
  ensure
    threads&.each do |thread|
      thread.kill if thread.alive?
      thread.join(5)
    end
  end

  it "posts exactly one reserve when two administrators hold it at once" do
    sell!
    outcomes = run_together(*Array.new(2) { -> { PayoutReserves.hold!(event: Event.find(event.id), actor: User.find(admin.id)) } })
    expect(outcomes.grep(BalanceAdjustment).length).to eq(1)
    expect(outcomes.grep(PayoutReserves::ReserveError).map(&:message)).to eq(["A reserve is already held for this event"])
    expect(event.balance_adjustments.where(kind: "reserve_hold").sum(:amount_cents)).to eq(-990)
  end

  it "never lets a reserve and a payout both take the full proceeds" do
    sell!
    approved_bank_account!(organization, actor: profile.user, admin: admin)
    settlement = Settlements::Finalizer.call(event: event, actor: admin)
    outcomes = run_together(
      -> { PayoutReserves.hold!(event: Event.find(event.id), actor: User.find(admin.id)) },
      -> { PayoutCreator.call(settlement: Settlement.find(settlement.id), actor: User.find(admin.id), idempotency_key: "race-both") }
    )
    hold = outcomes.grep(BalanceAdjustment).first
    payout = outcomes.grep(Payout).first
    if hold
      # The hold won: the old statement no longer matches, so the payout was refused.
      expect(outcomes.grep(PayoutCreator::PayoutError).map(&:message)).to eq(["Financial activity changed; finalize a new settlement before paying out"])
      expect(Payout.count).to eq(0)
    else
      expect(payout).to have_attributes(amount_cents: 9900)
      expect(outcomes.grep(PayoutReserves::ReserveError).map(&:message).sole).to include("already has a payout requested or sent")
      expect(BalanceAdjustment.count).to eq(0)
    end
  end
end
