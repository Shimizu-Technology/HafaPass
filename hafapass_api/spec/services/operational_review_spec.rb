require "rails_helper"
require "timeout"

RSpec.describe OperationalReview do
  self.use_transactional_tests = false

  after do
    if @receipt_id
      raise "Test database required" unless Rails.env.test? &&
        ApplicationRecord.connection.select_value("SELECT current_database()").end_with?("_test")

      MessageProviderEvent.where(id: @receipt_id).delete_all
    end
  end

  it "keeps the count and rows on one snapshot when a worker processes a receipt between their queries" do
    receipt = MessageProviderEvent.create!(provider: "resend", provider_event_id: SecureRandom.uuid,
      provider_message_id: "synthetic-snapshot", event_type: "email.delivered",
      occurred_at: 10.minutes.ago, received_at: 9.minutes.ago)
    @receipt_id = receipt.id
    processed = false
    subscriber = lambda do |*, payload|
      next unless !processed && payload[:sql].match?(/SELECT COUNT\(\*\).*message_provider_events/)

      processed = true
      worker = Thread.new do
        ApplicationRecord.connection_pool.with_connection do
          MessageProviderEvent.where(id: receipt.id).update_all(processed_at: Time.current)
        end
      end
      Timeout.timeout(5) { worker.value }
    end
    result = ActiveSupport::Notifications.subscribed(subscriber, "sql.active_record") do
      described_class.new.call(category: "stale_message_events")
    end
    expect(processed).to be(true)
    expect(result.dig(:signals, :stale_message_events)).to eq(1)
    expect(result.dig(:meta, :total_count)).to eq(1)
    expect(result.fetch(:items).pluck(:id)).to eq([receipt.id])
    expect(receipt.reload.processed_at).to be_present
    refreshed = described_class.new.call(category: "stale_message_events")
    expect(refreshed.dig(:signals, :stale_message_events)).to eq(0)
    expect(refreshed.fetch(:items)).to be_empty
  end
end
