# frozen_string_literal: true

require "rails_helper"

# Production QA in Stripe test mode: tickets work at the door while the
# platform stays in test mode, and stop working once payments are live.
RSpec.describe "Production admission of Stripe test-mode tickets" do
  let(:order) { create(:order) }

  before do
    create(:payment, :succeeded, order: order, amount_cents: 5250, provider_environment: "test",
      provider_platform_account_id: "acct_testplatform")
    allow(Rails.env).to receive(:production?).and_return(true)
  end

  it "admits a test-mode ticket while the platform is in test mode" do
    SiteSetting.instance.update!(payment_mode: "test")

    expect(order.reload.ticket_fulfilled?).to be(true)
  end

  it "refuses the same ticket after the switch to live payments" do
    SiteSetting.instance.update_column(:payment_mode, "live")

    expect(order.reload.ticket_fulfilled?).to be(false)
  end

  it "always admits a live-mode ticket" do
    live = create(:order, subtotal_cents: 1000, service_fee_cents: 0, total_cents: 1000)
    create(:payment, :succeeded, order: live, amount_cents: 1000, provider_environment: "live",
      provider_platform_account_id: "acct_liveplatform")
    SiteSetting.instance.update!(payment_mode: "test")

    expect(live.reload.ticket_fulfilled?).to be(true)
  end
end
