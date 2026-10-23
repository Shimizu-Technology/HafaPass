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
end
