require "rails_helper"
require "timeout"

RSpec.describe "Pending-order purge locking", :non_transactional do
  self.use_transactional_tests = false

  before do
    clean_test_data
    allow(ENV).to receive(:[]).and_call_original
    allow(ENV).to receive(:[]).with("DATA_RETENTION_DESTRUCTIVE_ENABLED").and_return("true")
    SiteSetting.instance.update_columns(retention_purge_enabled: true)
  end
  after { clean_test_data }

  it "rechecks a payment committed while purge waits for the order lock" do
    order = create(:order, :pending, created_at: 100.days.ago, expires_at: 100.days.ago)
    worker_pid = Queue.new
    outcome = Queue.new
    worker = nil

    Order.transaction do
      Order.find(order.id).lock!
      worker = Thread.new do
        ActiveRecord::Base.connection_pool.with_connection do |connection|
          worker_pid << connection.select_value("SELECT pg_backend_pid()")
          outcome << DataRetention.delete_pending_order!(Order.find(order.id))
        rescue StandardError => error
          outcome << error
        end
      end
      pid = Timeout.timeout(10) { worker_pid.pop }
      Timeout.timeout(10) do
        loop do
          waiting = ActiveRecord::Base.connection.select_value(
            "SELECT wait_event_type FROM pg_stat_activity WHERE pid = #{Integer(pid)}")
          break if waiting == "Lock"

          sleep 0.01
        end
      end
      create(:payment, order: order)
    end

    Timeout.timeout(10) { worker.join }
    expect(outcome.pop).to be(false)
    expect(Order.exists?(order.id)).to be(true)
    expect(Payment.where(order_id: order.id)).to exist
  ensure
    worker&.kill if worker&.alive?
    worker&.join
  end

  def clean_test_data
    unless Rails.env.test? && ActiveRecord::Base.connection_db_config.database.end_with?("_test")
      raise "Isolated test database required"
    end

    ActiveRecord::Base.connection.execute(<<~SQL)
      TRUNCATE TABLE audit_logs, audit_write_failures, organizations, users, organizer_profiles, events, site_settings, webhook_events, checkout_attempts
      RESTART IDENTITY CASCADE
    SQL
  end
end
