# frozen_string_literal: true

require "rails_helper"
require "timeout"

RSpec.describe PayoutReserves do
  include ActiveSupport::Testing::TimeHelpers

  let(:admin) { create(:user, :admin) }
  let(:profile) { create(:organizer_profile, :verified) }
  let(:organization) { profile.organization }
  let(:event) do
    create(:event, :completed, organization: organization, organizer_profile: profile,
      starts_at: guam(2027, 1, 30, 9), ends_at: guam(2027, 1, 30, 18))
  end
  let(:ticket_type) { create(:ticket_type, event: event, price_cents: 1700) }

  around do |example|
    example.metadata[:own_clock] ? example.run : travel_to(guam(2027, 2, 1, 10)) { example.run }
  end

  it "holds 10% of platform-held net proceeds, rounded half up, and dates its release in Guam" do
    # 7 × $17.00 − $3.95 processing = $115.05 → $11.505 → $11.51.
    record_card_sale!(event, ticket_type: ticket_type, quantity: 7, processing_fee_cents: 395)
    hold = described_class.hold!(event: event, actor: admin)
    expect(hold).to have_attributes(kind: "reserve_hold", amount_cents: -1151, event: event, status: "posted")
    expect(hold.reason).to eq("Chargeback reserve: 10% of $115.05 net proceeds, held until 2027-03-01")
    audit = AuditLog.find_by!(auditable: hold, action: "balance_adjustment.posted")
    expect(audit.metadata).to include("reserve_rate_bps" => 1000, "net_before_reserve_cents" => 11_505,
      "suggested_reserve_cents" => 1151, "release_on" => "2027-03-01", "source" => "payout_schedule")
    expect(Settlements::Calculator.call(event).attributes).to include(reserve_cents: 1151, payable_cents: 11_505 - 1151)
  end

  it "accepts an administrator's amount within the net proceeds and records that it was overridden" do
    record_card_sale!(event, ticket_type: ticket_type, quantity: 2, processing_fee_cents: 100)
    hold = described_class.hold!(event: event, actor: admin, amount_cents: "500", note: "Higher risk first event")
    expect(hold.amount_cents).to eq(-500)
    expect(hold.reason).to include("15.15%", "Higher risk first event")
    expect(AuditLog.find_by!(auditable: hold).metadata).to include("amount_overridden" => true)
    expect { described_class.hold!(event: event, actor: admin) }.to raise_error(described_class::ReserveError, /already held/)
    other = create(:event, :completed, organization: organization, organizer_profile: profile)
    record_card_sale!(other, ticket_type: create(:ticket_type, event: other, price_cents: 1000), processing_fee_cents: 30)
    expect { described_class.hold!(event: other, actor: admin, amount_cents: 971) }
      .to raise_error(described_class::ReserveError, "Reserve cannot be more than the event's net proceeds")
    expect { described_class.hold!(event: other, actor: admin, amount_cents: "1.5") }
      .to raise_error(described_class::ReserveError, "Reserve must be whole cents")
  end

  it "refuses non-admins, unfinished events, zero proceeds and events already paid" do
    record_card_sale!(event, ticket_type: ticket_type, quantity: 1, processing_fee_cents: 50)
    expect { described_class.hold!(event: event, actor: profile.user) }
      .to raise_error(described_class::ReserveError, "Administrator access is required")
    published = create(:event, :published, organization: organization, organizer_profile: profile)
    expect { described_class.hold!(event: published, actor: admin) }
      .to raise_error(described_class::ReserveError, "Complete the event before holding its reserve")
    empty = create(:event, :completed, organization: organization, organizer_profile: profile)
    expect { described_class.hold!(event: empty, actor: admin) }
      .to raise_error(described_class::ReserveError, "There are no platform-held proceeds to reserve")
    expect { described_class.release!(event: empty, actor: admin) }
      .to raise_error(described_class::ReserveError, "No reserve is held for this event")
    account = create(:connected_account, organization: organization, provider: "manual", with_readiness_approval: false)
    create(:payout, organization: organization, event: event, connected_account: account, status: :paid,
      provider_payout_id: "TRF-EARLIER")
    expect { described_class.hold!(event: event, actor: admin) }
      .to raise_error(described_class::ReserveError, /already has a payout requested or sent/)
    expect(BalanceAdjustment.count).to eq(0)
  end

  it "releases the whole held reserve after 30 days; a chargeback in the window reduces what is then owed", :own_clock do
    travel_to(guam(2027, 2, 1, 10)) do
      # 20 × $17.00 − $2.00 processing = $338.00; $33.80 held.
      order, _item, capture = record_card_sale!(event, ticket_type: ticket_type, quantity: 10, processing_fee_cents: 100)
      record_card_sale!(event, ticket_type: ticket_type, quantity: 10, processing_fee_cents: 100)
      described_class.hold!(event: event, actor: admin)
      expect(PayoutSchedule.for(event).reserve_held_cents).to eq(3380)
      record_lost_chargeback!(order, capture, amount_cents: 1800)
      expect(PayoutSchedule.for(event).owed_cents).to eq(33_800 - 3380 - 1800)
    end
    travel_to(guam(2027, 2, 28, 23, 59)) do
      expect { described_class.release!(event: event, actor: admin) }
        .to raise_error(described_class::ReserveError, /held until 2027-03-01/)
    end
    # Midnight in Guam is still Feb 28 in UTC: the Guam date governs.
    travel_to(guam(2027, 3, 1, 0, 5)) do
      expect(Time.current.utc.to_date).to eq(Date.new(2027, 2, 28))
      release = described_class.release!(event: event, actor: admin)
      expect(release).to have_attributes(kind: "reserve_release", amount_cents: 3380)
      after = PayoutSchedule.for(event)
      expect(after.reserve_held_cents).to eq(0)
      expect(after.reserve_released_cents).to eq(3380)
      expect(after.owed_cents).to eq(33_800 - 1800)
      expect { described_class.release!(event: event, actor: admin) }
        .to raise_error(described_class::ReserveError, "No reserve is held for this event")
    end
  end

  it "keeps a tax identifier out of an early-release reason" do
    record_card_sale!(event, ticket_type: ticket_type, quantity: 2, processing_fee_cents: 50)
    described_class.hold!(event: event, actor: admin)
    expect { described_class.release!(event: event, actor: admin, early_release_reason: "Approved for 123-45-6789 payee") }
      .to raise_error(described_class::ReserveError, BackupWithholding::TIN_WARNING)
  end
end

RSpec.describe PayoutReserves, "concurrency", :non_transactional do
  self.use_transactional_tests = false

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
  end
  after { clean_test_data }

  # Finding 2 of the PR #239 review: an order completion holds the event row
  # and then needs the organization FK KEY SHARE for its audit insert. A hold
  # that took the organization FOR UPDATE and then waited for the event made
  # PostgreSQL abort one side with a deadlock.
  it "does not deadlock with an order completion that holds the event and then writes its audit" do
    admin = create(:user, :admin)
    profile = create(:organizer_profile, :verified)
    organization = profile.organization
    event = create(:event, :completed, organization: organization, organizer_profile: profile)
    record_card_sale!(event, ticket_type: create(:ticket_type, event: event, price_cents: 2000), quantity: 5,
      processing_fee_cents: 100)
    event_held = Queue.new
    hold_pid = Queue.new
    results = Queue.new
    completion = Thread.new do
      ActiveRecord::Base.connection_pool.with_connection do |connection|
        Event.transaction do
          connection.execute("SET LOCAL lock_timeout = '8s'")
          Event.lock("FOR NO KEY UPDATE").find(event.id)
          event_held << true
          pid = hold_pid.pop
          Timeout.timeout(8) do
            sleep 0.02 until connection.select_value("SELECT cardinality(pg_blocking_pids(#{pid.to_i}))").to_i.positive?
          end
          # What an AuditLog (or any organization FK) insert takes.
          connection.execute("SELECT 1 FROM organizations WHERE id = #{organization.id.to_i} FOR KEY SHARE")
        end
        results << :completion_committed
      rescue StandardError => error
        results << error
      end
    end
    reserve = Thread.new do
      ActiveRecord::Base.connection_pool.with_connection do |connection|
        hold_pid << connection.select_value("SELECT pg_backend_pid()")
        event_held.pop
        connection.execute("SET lock_timeout = '8s'")
        results << described_class.hold!(event: Event.find(event.id), actor: User.find(admin.id))
      ensure
        connection.execute("SET lock_timeout = DEFAULT")
      end
    rescue StandardError => error
      results << error
    end
    Timeout.timeout(20) { [completion, reserve].each(&:join) }
    outcomes = Array.new(2) { results.pop }
    expect(outcomes.grep(StandardError)).to eq([])
    expect(outcomes).to include(:completion_committed)
    expect(outcomes.grep(BalanceAdjustment).sole.amount_cents).to eq(-990)
  end

  it "posts exactly one reserve when two administrators hold it at once" do
    admin = create(:user, :admin)
    profile = create(:organizer_profile, :verified)
    event = create(:event, :completed, organization: profile.organization, organizer_profile: profile)
    record_card_sale!(event, ticket_type: create(:ticket_type, event: event, price_cents: 2000), quantity: 5,
      processing_fee_cents: 100)
    ready = Queue.new
    start = Queue.new
    results = Queue.new
    threads = Array.new(2) do
      Thread.new do
        ActiveRecord::Base.connection_pool.with_connection do
          ready << true
          start.pop
          results << described_class.hold!(event: Event.find(event.id), actor: User.find(admin.id))
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
    outcomes = Array.new(2) { results.pop }
    expect(outcomes.grep(BalanceAdjustment).length).to eq(1)
    expect(outcomes.grep(described_class::ReserveError).map(&:message)).to eq(["A reserve is already held for this event"])
    expect(event.balance_adjustments.where(kind: "reserve_hold").sum(:amount_cents)).to eq(-990)
  end
end
