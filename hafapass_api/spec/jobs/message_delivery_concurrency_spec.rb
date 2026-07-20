require "rails_helper"
require "timeout"

RSpec.describe MessageDeliveryJob, :non_transactional do
  self.use_transactional_tests = false

  before do
    raise "Concurrency specs must only run in test" unless Rails.env.test?

    clean_test_data
  end

  after do
    clean_test_data
  end

  it "serializes duplicate jobs so the provider is called once" do
    delivery = create(:message_delivery)
    entered_provider = Queue.new
    release_provider = Queue.new
    calls = Queue.new
    allow(EmailService).to receive(:send_order_confirmation) do
      calls << true
      entered_provider << true
      release_provider.pop
      { id: "provider_once" }
    end

    first = Thread.new { run_job(delivery.id) }
    Timeout.timeout(5) { entered_provider.pop }
    second = Thread.new { run_job(delivery.id) }

    sleep 0.1
    expect(calls.size).to eq(1)
    release_provider << true
    Timeout.timeout(5) { [first, second].each(&:join) }

    expect(calls.size).to eq(1)
    expect(delivery.reload).to have_attributes(status: "sent", provider_id: "provider_once", attempts: 1)
  ensure
    release_provider << true if release_provider&.empty?
    [first, second].compact.each { |thread| thread.kill if thread.alive? }
  end

  private

  def run_job(delivery_id)
    ActiveRecord::Base.connection_pool.with_connection do
      described_class.new.perform(delivery_id)
    end
  end

  def clean_test_data
    ActiveRecord::Base.connection.execute(<<~SQL)
      TRUNCATE TABLE users, organizer_profiles, events, site_settings, webhook_events
      RESTART IDENTITY CASCADE
    SQL
  end
end
