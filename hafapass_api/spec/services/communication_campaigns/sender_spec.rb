require "rails_helper"

RSpec.describe CommunicationCampaigns::Sender do
  it "deduplicates recipients and records durable deliveries" do
    event = create(:event, :published)
    event.organization.update!(marketing_mailing_address: "123 Marine Drive, Hagåtña, GU 96910",
      marketing_address_certified_at: Time.current)
    type = create(:ticket_type, event: event)
    order = create(:order, event: event, buyer_email: "buyer@example.com", marketing_opt_in: true)
    item = create(:order_item, order: order, ticket_type: type, quantity: 2, subtotal_cents: 5000)
    create_list(:ticket, 2, order: order, event: event, ticket_type: type, order_item: item,
      holder_email: "Buyer@Example.com")
    campaign = create(:communication_campaign, event: event)

    expect { described_class.call(campaign) }.to change(MessageDelivery, :count).by(1)
    expect(campaign.reload).to be_sending
    expect(campaign.recipient_count).to eq(1)
    expect(campaign.message_deliveries.first.metadata).to include("subject" => campaign.subject, "body" => campaign.body)
  end

  it "keeps a dispatcher enqueue failure recoverable without creating more recipients" do
    campaign = create(:communication_campaign)
    campaign.event.organization.update!(marketing_mailing_address: "123 Marine Drive, Hagåtña, GU 96910",
      marketing_address_certified_at: Time.current)
    # Execute the post-commit boundary explicitly under the test fixture's
    # enclosing transaction; production registers it after all real commits.
    callbacks = []
    allow(ActiveRecord).to receive(:after_all_transactions_commit) { |&block| callbacks << block }
    allow(CommunicationCampaignDispatchJob).to receive(:perform_later).and_return(false)
    described_class.call(campaign)
    expect(campaign.reload).to be_sending
    expect { callbacks.shift.call }.to raise_error(ActiveJob::EnqueueError)
    expect(campaign.reload).to be_failed
    expect(AuditLog.where(auditable: campaign, action: "campaign.send_completed")).not_to exist
    expect(AuditLog.find_by!(auditable: campaign, action: "campaign.send_failed").metadata)
      .to include("failure_code" => "dispatcher_enqueue_failed")
    expect { described_class.call(campaign) }.not_to change(MessageDelivery, :count)
    expect(campaign.reload).to be_sending
  end

  it "reauthorizes scheduled campaigns at execution and leaves a visible attention reason" do
    event = create(:event, :published)
    scheduler = create(:user)
    membership = create(:organization_membership, organization: event.organization, user: scheduler, role: :marketer)
    campaign = create(:communication_campaign, event: event, scheduled_by_user: scheduler,
      scheduled_at: 1.minute.ago, status: :scheduled)
    membership.update!(expires_at: 1.second.ago)
    expect { CommunicationCampaignJob.perform_now(campaign.id) }.not_to change(MessageDelivery, :count)
    expect(campaign.reload).to be_failed
    expect(campaign.last_error).to include("Needs attention", "no longer has permission")
    expect(campaign.sent_by_user).to be_nil
  end

  it "attributes send-now deliveries to the sender rather than the campaign author" do
    event = create(:event, :published)
    event.organization.update!(marketing_mailing_address: "123 Marine Drive, Hagåtña, GU 96910",
      marketing_address_certified_at: Time.current)
    sender = create(:user)
    create(:organization_membership, organization: event.organization, user: sender, role: :manager)
    type = create(:ticket_type, event: event)
    order = create(:order, event: event, buyer_email: "opted-in@example.com", marketing_opt_in: true)
    create(:ticket, order: order, event: event, ticket_type: type)
    campaign = create(:communication_campaign, event: event)
    described_class.call(campaign, actor: sender)
    expect(campaign.reload.sent_by_user).to eq(sender)
    expect(campaign.message_deliveries.first.requested_by).to eq(sender)
  end
  it "recovers the same outbox under a newly authorized sender without replaying completed deliveries" do
    campaign = create(:communication_campaign, status: :failed, started_at: 1.hour.ago,
      last_error: CommunicationCampaign::AUTHORIZATION_ERROR)
    campaign.event.organization.update!(marketing_mailing_address: "123 Marine Drive, Hagåtña, GU 96910",
      marketing_address_certified_at: Time.current)
    former = create(:user)
    blocked = create(:message_delivery, communication_campaign: campaign, event: campaign.event,
      requested_by: former, status: :cancelled, last_error: CommunicationCampaign::DELIVERY_AUTHORIZATION_ERROR)
    sent = create(:message_delivery, communication_campaign: campaign, event: campaign.event,
      requested_by: former, status: :sent, provider_id: "provider-already-sent")
    sender = campaign.event.organizer_profile.user
    expect { described_class.call(campaign, actor: sender) }.not_to change(MessageDelivery, :count)
    expect(campaign.reload).to have_attributes(status: "sending", sent_by_user_id: sender.id, last_error: nil)
    expect(blocked.reload).to have_attributes(status: "queued", requested_by_id: sender.id, last_error: nil)
    expect(sent.reload).to have_attributes(status: "sent", provider_id: "provider-already-sent", requested_by_id: former.id)
    expect(AuditLog.where(auditable: campaign, action: "campaign.recovered", actor_user: sender)).to exist
  end
end
