# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Campaign durable enqueue boundary", :non_transactional do
  self.use_transactional_tests = false

  before { reset_fixtures }
  after { reset_fixtures }

  it "commits the outbox before dispatch, preserves the sender, and recovers a real adapter rejection" do
    event = create(:event, :published)
    event.organization.update!(marketing_mailing_address: "123 Marine Drive, Hagåtña, GU 96910",
      marketing_address_certified_at: Time.current)
    type = create(:ticket_type, event: event)
    order = create(:order, event: event, buyer_email: "campaign@example.com", marketing_opt_in: true)
    create(:ticket, order: order, event: event, ticket_type: type)
    campaign = create(:communication_campaign, event: event)
    sender = create(:user)
    create(:organization_membership, organization: event.organization, user: sender, role: :marketer)
    adapter = ActiveJob::Base.queue_adapter

    CommunicationCampaigns::Sender.call(campaign, actor: sender)
    expect(campaign.reload).to be_sending
    payload = adapter.enqueued_jobs.find { |job| job[:job] == CommunicationCampaignDispatchJob }
    expect(payload).to be_present
    expect(AuditLog.where(action: "campaign.send_completed", auditable: campaign)).not_to exist
    allow(adapter).to receive(:enqueue).and_call_original
    allow(adapter).to receive(:enqueue).with(an_instance_of(MessageDeliveryJob)) do
      Thread.new do
        ActiveRecord::Base.connection_pool.with_connection do
          expect(CommunicationCampaign.find(campaign.id)).to be_sending
          expect(MessageDelivery.where(communication_campaign_id: campaign.id).count).to eq(1)
        end
      end.value
      raise ActiveJob::EnqueueError, "Queue unavailable"
    end

    ActiveJob::Base.execute(payload)
    expect(campaign.reload).to be_failed
    expect(campaign.sent_at).to be_nil
    expect(AuditLog.find_by!(action: "campaign.send_failed", auditable: campaign).actor_user_id).to eq(sender.id)
    expect(AuditLog.where(action: "campaign.send_completed", auditable: campaign)).not_to exist

    allow(adapter).to receive(:enqueue).with(an_instance_of(MessageDeliveryJob)).and_call_original
    ActiveJob::Base.execute(payload)
    expect(campaign.reload).to be_sent
    expect(campaign.message_deliveries.count).to eq(1)
    expect(AuditLog.find_by!(action: "campaign.send_completed", auditable: campaign).actor_user_id).to eq(sender.id)
  end

  def reset_fixtures
    raise "Isolated test database required" unless Rails.env.test? &&
      ActiveRecord::Base.connection_db_config.database.end_with?("_test")

    ActiveRecord::Base.connection.execute("TRUNCATE TABLE audit_logs, audit_write_failures, users, organizations, events, site_settings RESTART IDENTITY CASCADE")
    ActiveJob::Base.queue_adapter.enqueued_jobs.clear
  end
end
