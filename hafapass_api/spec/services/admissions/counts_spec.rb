# frozen_string_literal: true

require "rails_helper"

RSpec.describe Admissions::Counts do
  let(:event) { create(:event, :published) }
  let(:order) { create(:order, event: event) }
  let!(:ticket) { create(:ticket, event: event, order: order, ticket_type: create(:ticket_type, event: event)) }

  it "uses current production payment eligibility without relabeling issued tickets as available entry" do
    create(:payment, :succeeded, order: order, provider_environment: "test")
    settings = SiteSetting.instance
    allow(SiteSetting).to receive(:instance).and_return(settings)
    allow(Rails).to receive(:env).and_return(ActiveSupport::StringInquirer.new("production"))
    allow(settings).to receive(:payment_mode).and_return("live")
    expect(described_class.call(event: event)).to include(issued: 1, remaining: 1, eligible_unadmitted: 0, admitted: 0)
    allow(settings).to receive(:payment_mode).and_return("test")
    expect(described_class.call(event: event)).to include(issued: 1, eligible_unadmitted: 1)
  end

  it "does not include disputed or unpublished tickets in eligible entry" do
    # Use persisted dispute state, so the bulk loader must honor its association.
    Dispute.create!(order: order, provider: "stripe", provider_dispute_id: "dp_counts",
      amount_cents: order.total_cents, currency: "usd", status: :open, opened_at: Time.current)
    expect(described_class.call(event: event)).to include(issued: 1, eligible_unadmitted: 0)
    event.update!(status: :cancelled)
    expect(described_class.call(event: event)).to include(issued: 1, eligible_unadmitted: 0)
  end
end
