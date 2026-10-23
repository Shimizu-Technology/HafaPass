# frozen_string_literal: true

require "rails_helper"

RSpec.describe CommunicationCampaignDispatchJob do
  let(:event) { create(:event) }
  let(:event_owner) { event.organizer_profile.user }
  let(:campaign) { create(:communication_campaign, event: event, status: :sending, sent_by_user: event_owner, started_at: Time.current, recipient_count: 2) }
  let!(:first) { create(:message_delivery, communication_campaign: campaign, event: campaign.event) }
  let!(:second) { create(:message_delivery, communication_campaign: campaign, event: campaign.event) }
  let(:accepted_job) { instance_double(MessageDeliveryJob, successfully_enqueued?: true) }

  it "records completion only after every child enqueue succeeds" do
    allow(MessageDeliveryJob).to receive(:perform_later) do
      expect(campaign.reload).to be_sending
      expect(AuditLog.where(auditable: campaign, action: "campaign.send_completed")).not_to exist
      accepted_job
    end
    described_class.new.perform(campaign.id)
    expect(campaign.reload).to be_sent
    expect(AuditLog.where(auditable: campaign, action: "campaign.send_completed")).to exist
  end

  it "leaves partial failures recoverable and retries the same durable deliveries" do
    allow(MessageDeliveryJob).to receive(:perform_later).with(first.id).and_return(accepted_job)
    allow(MessageDeliveryJob).to receive(:perform_later).with(second.id).and_raise(IOError, "private provider detail")
    expect { described_class.new.perform(campaign.id) }.to raise_error(IOError)
    expect(campaign.reload).to be_failed
    expect(campaign.sent_at).to be_nil
    expect(campaign.message_deliveries.count).to eq(2)
    expect(AuditLog.where(auditable: campaign, action: "campaign.send_completed")).not_to exist
    failure = AuditLog.find_by!(auditable: campaign, action: "campaign.send_failed")
    expect(failure.metadata).to include("failure_code" => "delivery_enqueue_failed")
    expect(failure.attributes.to_json).not_to include("private provider detail")

    allow(MessageDeliveryJob).to receive(:perform_later).with(second.id).and_return(accepted_job)
    described_class.new.perform(campaign.id)
    expect(campaign.reload).to be_sent
    expect(campaign.message_deliveries.pluck(:id)).to match_array([first.id, second.id])
    expect(AuditLog.where(auditable: campaign, action: "campaign.send_completed").count).to eq(1)
  end

  it "treats a false enqueue return as failure" do
    allow(MessageDeliveryJob).to receive(:perform_later).and_return(false)
    expect { described_class.new.perform(campaign.id) }.to raise_error(ActiveJob::EnqueueError)
    expect(campaign.reload).to be_failed
  end

  it "blocks a revoked sender on dispatch and requires explicit authorized recovery" do
    membership = event.organization.organization_memberships.find_by!(user: event_owner)
    membership.update!(status: :revoked)
    allow(MessageDeliveryJob).to receive(:perform_later).and_return(accepted_job)

    described_class.new.perform(campaign.id)
    expect(campaign.reload).to be_failed
    expect(campaign.last_error).to eq(CommunicationCampaign::AUTHORIZATION_ERROR)
    expect(MessageDeliveryJob).not_to have_received(:perform_later)
    expect(AuditLog.where(auditable: campaign, action: "campaign.reauthorization_failed").count).to eq(1)
    membership.update!(status: :active)
    described_class.new.perform(campaign.id)
    expect(campaign.reload).to be_failed
    expect(MessageDeliveryJob).not_to have_received(:perform_later)
  end

  it "rechecks the authorization-failure state after an organization lock wait" do
    campaign
    allow_any_instance_of(Organization).to receive(:lock!).and_wrap_original do |method, *args|
      campaign.update!(status: :failed, last_error: CommunicationCampaign::AUTHORIZATION_ERROR)
      method.call(*args)
    end
    allow(MessageDeliveryJob).to receive(:perform_later).and_return(accepted_job)
    described_class.new.perform(campaign.id)
    expect(campaign.reload).to be_failed
    expect(MessageDeliveryJob).not_to have_received(:perform_later)
    expect(AuditLog.where(auditable: campaign, action: "campaign.send_completed")).not_to exist
  end

  it "does not create completion from a status update alone" do
    campaign.update!(status: :sent)
    expect(AuditLog.where(auditable: campaign, action: "campaign.send_completed")).not_to exist
  end
end
