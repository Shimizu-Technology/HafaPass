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

  def clean_test_data
    ActiveRecord::Base.connection.execute(<<~SQL)
      TRUNCATE TABLE users, organizer_profiles, events, site_settings, webhook_events, checkout_attempts
      RESTART IDENTITY CASCADE
    SQL
  end
end
