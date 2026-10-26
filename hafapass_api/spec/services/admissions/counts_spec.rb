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
  it "matches domain eligibility across production payment/refund/retention edge cases without hydrating event records" do
    settings = SiteSetting.instance
    type = ticket.ticket_type
    variants = [
      {}, { provider_environment: "test" }, { provider_environment: "unknown" },
      { provider_payment_id: "sim_fake" }, { provider_payment_id: " \t" }, { provider_payment_id: "\u00a0" },
      { provider_platform_account_id: " " }, { currency: "eur" }, { amount_cents: 1 },
      { provider_payload: { simulated: true } }, { provider_payload: { simulated: "true" } },
      { status: :partially_refunded }, { status: :refunded }, { provider: "manual", provider_platform_account_id: nil }
    ]
    variants.each_with_index do |attributes, index|
      row = create(:order, event: event)
      create(:ticket, event: event, order: row, ticket_type: type)
      payment = build(:payment, :succeeded, order: row, **{ provider_environment: "live" }.merge(attributes))
      payment.save!(validate: false) # Synthetic legacy provider states are intentional.
      if index == 0
        pending = create(:refund, order: row, status: :pending, amount_cents: 1000, succeeded_at: nil)
        pending.refund_tickets.create!(ticket: row.tickets.first, amount_cents: 1000, released_at: Time.current)
      elsif index == 1
        create(:refund, order: row, status: :pending, amount_cents: row.total_cents, succeeded_at: nil)
      end
    end
    free = create(:order, event: event, subtotal_cents: 0, total_cents: 0, service_fee_cents: 0)
    create(:ticket, event: event, order: free, ticket_type: type)
    allow(Rails).to receive(:env).and_return(ActiveSupport::StringInquirer.new("production"))
    allow(SiteSetting).to receive(:instance).and_return(settings)
    %w[live test].each do |mode|
      allow(settings).to receive(:payment_mode).and_return(mode)
      expected = event.tickets.includes(:event, :inventory_retention, :pending_refund_tickets,
        order: [:payments, :refunds, :disputes]).count(&:admission_allowed?)
      instantiated = []
      callback = ->(*args) { instantiated << args.last }
      actual = ActiveSupport::Notifications.subscribed(callback, "instantiation.active_record") { described_class.call(event: event) }
      expect(actual[:eligible_unadmitted]).to eq(expected)
      expect(instantiated).to be_empty
    end
  end
end
