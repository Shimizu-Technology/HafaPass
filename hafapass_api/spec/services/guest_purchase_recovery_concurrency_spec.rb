require "rails_helper"
require "timeout"

RSpec.describe GuestPurchaseRecovery, :non_transactional do
  self.use_transactional_tests = false

  before do
    raise "Recovery concurrency specs must only run in test" unless Rails.env.test?

    clean_test_data
    allow(ClerkIdentity).to receive(:verified_email_addresses).and_return(["buyer@example.com"])
  end

  after { clean_test_data }

  it "commits one recovery for simultaneous retries" do
    user = create(:user)
    order = create(:order, buyer_email: "buyer@example.com")
    ticket = create(:ticket, order: order)
    outcomes = recover_concurrently([user, user])

    expect(outcomes.sum { |result| result.fetch(:recovered_orders_count) }).to eq(1)
    expect(outcomes.sum { |result| result.fetch(:recovered_tickets_count) }).to eq(1)
    expect(order.reload.user).to eq(user)
    expect(ticket.reload.holder_user).to eq(user)
    expect(AuditLog.where(action: "guest_purchase.recovered").count).to eq(1)
  end

  it "does not overwrite a competing account claim or separate payer from holder" do
    users = create_list(:user, 2)
    order = create(:order, buyer_email: "buyer@example.com")
    ticket = create(:ticket, order: order)
    outcomes = recover_concurrently(users)

    expect(outcomes.map { |result| result.fetch(:recovered_orders_count) }.sort).to eq([0, 1])
    expect(users.map(&:id)).to include(order.reload.user_id)
    expect(ticket.reload.holder_user_id).to eq(order.user_id)
    expect(AuditLog.where(action: "guest_purchase.recovered").count).to eq(1)
  end

  def recover_concurrently(users)
    ready = Queue.new
    start = Queue.new
    results = Queue.new
    threads = users.map do |user|
      Thread.new do
        ActiveRecord::Base.connection_pool.with_connection do
          ready << true
          start.pop
          results << described_class.call(user: User.find(user.id))
        rescue StandardError => error
          results << error
        end
      end
    end
    Timeout.timeout(15) do
      users.length.times { ready.pop }
      users.length.times { start << true }
      threads.each(&:join)
      users.length.times.map { results.pop }
    end
  ensure
    threads&.each { |thread| thread.kill if thread.alive? }
  end

  def clean_test_data
    ActiveRecord::Base.connection.execute("TRUNCATE TABLE users, organizer_profiles, events, site_settings, webhook_events RESTART IDENTITY CASCADE")
  end
end
