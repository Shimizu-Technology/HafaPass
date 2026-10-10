require "rails_helper"

RSpec.describe FulfillmentResender do
  let(:order) { create(:order) }

  before { allow(EmailService).to receive(:send_order_confirmation_async) }

  MessageDelivery.statuses.keys.each do |status|
    it "keeps the two-minute request cooldown after a quick #{status} result" do
      create(:message_delivery, order: order, template: "fulfillment_resend", status: status)
      expect { described_class.call(order: order) }.to raise_error(described_class::Cooldown)
      expect(EmailService).not_to have_received(:send_order_confirmation_async)
    end
  end

  %w[order_confirmation fulfillment_resend].each do |template|
    [1.minute.ago, 2.days.ago].each do |created_at|
      it "preserves an unresolved #{template} operation at age #{created_at} without another delivery/key/job" do
        delivery = create(:message_delivery, order: order, template: template, status: :failed,
          provider_outcome_unknown: true, provider_attempted_at: created_at, created_at: created_at)
        snapshot = delivery.reload.attributes
        count = MessageDelivery.count
        expect { described_class.call(order: order) }.to raise_error(described_class::Unconfirmed)
        expect(MessageDelivery.count).to eq(count)
        expect(delivery.reload.attributes).to eq(snapshot)
        expect(EmailService).not_to have_received(:send_order_confirmation_async)
      end
    end
  end

  it "refuses an old legacy attempted unacknowledged operation without inventing a new key" do
    delivery = create(:message_delivery, order: order, template: "order_confirmation", status: :failed,
      provider_outcome_unknown: false, provider_attempted_at: nil, attempts: 1, created_at: 2.days.ago)
    snapshot = delivery.reload.attributes
    expect { described_class.call(order: order) }.to raise_error(described_class::Unconfirmed)
    expect(delivery.reload.attributes).to eq(snapshot)
    expect(EmailService).not_to have_received(:send_order_confirmation_async)
  end

  it "does not apply an unrelated campaign, recovery template or another order's uncertainty to this resend" do
    create(:message_delivery, order: order, template: "communication_campaign", provider_outcome_unknown: true)
    create(:message_delivery, order: order, template: "order_recovery", provider_outcome_unknown: true)
    create(:message_delivery, template: "order_confirmation", provider_outcome_unknown: true)
    create(:message_delivery, order: order, channel: "sms", template: "order_confirmation", provider_outcome_unknown: true)
    described_class.call(order: order)
    expect(EmailService).to have_received(:send_order_confirmation_async).with(order, requested_by: nil, template: "fulfillment_resend")
  end

  it "permits an explicitly requested known-acknowledged sent or delayed resend after the cooldown" do
    %i[sent delayed].each do |status|
      create(:message_delivery, order: order, template: "fulfillment_resend", status: status,
        provider_id: "known-provider-id-#{status}", attempts: 1, provider_attempted_at: nil, created_at: 3.minutes.ago)
    end
    described_class.call(order: order)
    expect(EmailService).to have_received(:send_order_confirmation_async).once
  end

  it "does not clear an explicit unknown flag merely because a historical provider id exists" do
    create(:message_delivery, order: order, template: "order_confirmation", provider_id: "historical-provider-id",
      provider_outcome_unknown: true, created_at: 3.days.ago)
    expect { described_class.call(order: order) }.to raise_error(described_class::Unconfirmed)
    expect(EmailService).not_to have_received(:send_order_confirmation_async)
  end
end
