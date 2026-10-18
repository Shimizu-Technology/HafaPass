require "rails_helper"
require "timeout"

RSpec.describe "Payout reconciliation concurrency", :non_transactional do
  self.use_transactional_tests = false

  before do
    raise "Concurrency fixtures require test" unless Rails.env.test?

    clean_test_data
  end
  after { clean_test_data }

  it "commits only one of competing paid and failed outcomes" do
    organization = create(:organization)
    profile = create(:organizer_profile, organization: organization)
    event = create(:event, :completed, organization: organization, organizer_profile: profile)
    settlement = create(:settlement, organization: organization, event: event)
    account = create(:connected_account, organization: organization, provider: "manual", with_readiness_approval: false)
    payout = create(:payout, organization: organization, event: event, settlement: settlement,
      connected_account: account, status: :processing, created_at: 1.hour.ago)
    admin = create(:user, :admin)
    ready = Queue.new
    start = Queue.new
    results = Queue.new
    threads = %w[paid failed].map do |status|
      Thread.new do
        ActiveRecord::Base.connection_pool.with_connection do
          ready << true
          start.pop
          results << PayoutReconciler.call(payout: Payout.find(payout.id), actor: User.find(admin.id), status: status,
            provider_payout_id: "bank-transfer-fixture", evidence: {
              reference: "bank/#{status}", confirmed_at: 1.minute.ago.iso8601, reason: "Confirmed #{status} outcome"
            })
        rescue StandardError => error
          results << error
        end
      end
    end
    Timeout.timeout(10) do
      2.times { ready.pop }
      2.times { start << true }
      threads.each(&:join)
    end
    outcomes = 2.times.map { results.pop }
    expect(outcomes.grep(Payout).length).to eq(1)
    expect(outcomes.grep(PayoutReconciler::ReconciliationError).length).to eq(1)
    audits = AuditLog.where(auditable: payout, action: "payout.reconciled")
    expect(audits.count).to eq(1)
    expect(audits.first.after_data.fetch("status")).to eq(payout.reload.status)
  ensure
    threads&.each { |thread| thread.kill if thread.alive? }
    threads&.each(&:join)
  end

  [[:processing, "paid"], [:rejection, "paid"], [:timeout, "paid"], [:paid, "failed"], [:paid, "reversed"]].each do |reply, reconciled_status|
    it "protects a #{reconciled_status} reconciliation from a late #{reply} submission" do
      profile = create(:organizer_profile, :verified)
      organization = profile.organization
      event = create(:event, :completed, organizer_profile: profile)
      order = create(:order, event: event, subtotal_cents: 5000, service_fee_cents: 0,
        discount_cents: 0, total_cents: 5000)
      create(:order_item, order: order, unit_price_cents: 5000, subtotal_cents: 5000,
        fee_cents: 0, organizer_proceeds_cents: 5000)
      create(:payment, :succeeded, order: order, provider_environment: "simulate", provider_payment_id: "sim_fixture")
      create(:connected_account, organization: organization)
      settlement = Settlements::Finalizer.call(event: event, actor: profile.user)
      admin = create(:user, :admin)
      entered = Queue.new
      resume = Queue.new
      result = Queue.new
      allow(Sentry).to receive(:capture_exception)
      allow(PayoutGateway).to receive(:submit) do |reserved|
        entered << reserved.id
        resume.pop
        raise PayoutGateway::PayoutError, "Rejected" if reply == :rejection
        raise IOError, "Connection lost" if reply == :timeout

        PayoutGateway::Result.new(provider_payout_id: reply == :paid ? "bank-transfer-fixture" : "manual_po_fixture",
          status: reply)
      end
      thread = Thread.new do
        ActiveRecord::Base.connection_pool.with_connection do
          result << PayoutCreator.call(settlement: Settlement.find(settlement.id),
            actor: User.find(profile.user_id), idempotency_key: "paused-submit")
        rescue StandardError => error
          result << error
        end
      end
      Timeout.timeout(10) do
        payout = Payout.find(entered.pop)
        evidence = { reference: "bank/#{reconciled_status}", confirmed_at: Time.current.iso8601(6),
          reason: "Verified external outcome" }
        PayoutReconciler.call(payout: payout, actor: admin, status: reconciled_status,
          provider_payout_id: "bank-transfer-fixture", evidence: evidence)
        resume << true
        thread.join
        outcome = result.pop
        if %i[rejection timeout].include?(reply)
          expect(outcome).to be_a(PayoutCreator::PayoutError)
        else
          expect(outcome).to be_a(Payout)
        end
        payout.reload
        if reply == :paid && reconciled_status == "failed"
          expect(payout).to have_attributes(status: "processing", failure_code: "provider_result_conflict")
          expect(OrganizationPayoutBalance.available_cents(organization)).to eq(0)
          expect(settlement.available_to_payout_cents).to eq(0)
          conflict = AuditLog.find_by!(auditable: payout, action: "payout.provider_result_conflict")
          expect do
            PayoutReconciler.call(payout: payout, actor: admin, status: "failed",
              provider_payout_id: "bank-transfer-fixture", evidence: evidence)
          end.to raise_error(PayoutReconciler::ReconciliationError, /latest provider conflict/)
          expect(payout.reload.failure_code).to eq("provider_result_conflict")
          expect(OrganizationPayoutBalance.available_cents(organization)).to eq(0)
          PayoutReconciler.call(payout: payout, actor: admin, status: "paid",
            provider_payout_id: "bank-transfer-fixture", evidence: evidence.merge(
              reference: "bank/confirmed-late-payment", conflict_audit_id: conflict.id))
          expect(payout.reload).to have_attributes(status: "paid", failure_code: nil)
        else
          expect(payout.status).to eq(reconciled_status)
          expect(AuditLog.where(auditable: payout, action: "payout.late_result_ignored")).to exist
        end
        expect(payout.provider_payout_id).to eq("bank-transfer-fixture")
        expect(AuditLog.where(auditable: payout, action: "payout.reconciled").first.after_data.fetch("status"))
          .to eq(reconciled_status)
        expect(OrganizationPayoutBalance.available_cents(organization)).to eq(reconciled_status == "reversed" ? 5000 : 0)
        expect(PayoutGateway).to have_received(:submit).once
      end
    ensure
      thread&.kill if thread&.alive?
      thread&.join
    end
  end

  def clean_test_data
    ActiveRecord::Base.connection.execute(<<~SQL)
      TRUNCATE TABLE organizations, users, organizer_profiles, events, site_settings, webhook_events, checkout_attempts
      RESTART IDENTITY CASCADE
    SQL
  end
end
