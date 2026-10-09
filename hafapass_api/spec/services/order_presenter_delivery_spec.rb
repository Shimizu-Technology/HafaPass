# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Order confirmation delivery state" do
  let(:order) { create(:order) }

  it "does not claim delivery when no message has been created" do
    expect(OrderPresenter.call(order)).not_to have_key(:confirmation_delivery)
  end

  it "distinguishes simulated processing from real email delivery" do
    create(:message_delivery, order: order, template: "order_confirmation", provider: "simulated", status: :sent)
    expect(OrderPresenter.call(order)[:confirmation_delivery]).to include(status: "sent", simulated: true)
  end

  it "reports the latest confirmation attempt instead of an unrelated reminder" do
    create(:message_delivery, order: order, template: "order_confirmation", provider: "resend", status: :delivered)
    create(:message_delivery, order: order, template: "fulfillment_resend", provider: "resend", status: :failed)
    create(:message_delivery, order: order, template: "event_reminder", status: :sent)
    delivery = OrderPresenter.call(order)[:confirmation_delivery]
    expect(delivery).to include(status: "failed", simulated: false)
    expect(delivery).not_to have_key(:provider_id)
  end

  it "keeps preloaded delivery associations consistent with database-backed presentation" do
    create(:message_delivery, order: order, provider: "resend", status: :queued)
    expected = OrderPresenter.call(order)[:confirmation_delivery]
    order.message_deliveries.load
    expect(OrderPresenter.call(order)[:confirmation_delivery]).to eq(expected)
  end
end
