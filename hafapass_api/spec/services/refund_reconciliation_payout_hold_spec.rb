require "rails_helper"

RSpec.describe "Unresolved refund payout protection" do
  let(:admin) { create(:user, :admin) }
  let(:profile) { create(:organizer_profile) }
  let(:event) { create(:event, :completed, organizer_profile: profile) }
  let(:settlement) { create(:settlement, event: event, organization: event.organization) }

  before do
    order = create(:order, event: event)
    payment = create(:payment, :succeeded, order: order, provider_environment: "live")
    create(:refund, order: order, payment: payment, status: :failed,
      succeeded_at: nil, failed_at: 4.days.ago, created_at: 4.days.ago)
  end

  it "blocks a new payout while a failed refund still owes the buyer" do
    creator = PayoutCreator.new(settlement: settlement, actor: admin, idempotency_key: "refund-hold-spec")

    expect { creator.send(:reserve!) }
      .to raise_error(PayoutCreator::PayoutError, /refund|liability|buyer/i)
    expect(Payout.where(idempotency_key: "refund-hold-spec")).not_to exist
  end

  it "keeps an existing payout on hold while a failed refund remains unresolved" do
    payout = create(:payout, event: event, organization: event.organization, settlement: settlement,
      status: :held, held_from_status: "pending", with_tax_snapshot: false)

    expect { PayoutHoldRelease.call(payout: payout, actor: admin) }
      .to raise_error(PayoutHoldRelease::ReleaseError, /refund|liability|buyer/i)
    expect(payout.reload).to be_status_held
  end
end
