require "rails_helper"

RSpec.describe LiveMoneyProofAuthorizations::Manager do
  it "requires independent approval and consumes one exact hidden proof order" do
    stub_live_money_provider_ready
    profile = create(:organizer_profile, :payout_ready)
    event = create(:event, :published, organizer_profile: profile, organization: profile.organization,
      title: "[LIVE MONEY TEST] Authorization", max_capacity: 1, live_money_proof_candidate: true)
    create(:ticket_type, event: event, price_cents: 100, quantity_available: 1, max_per_order: 1, max_per_buyer: 1)
    create_event_day_rehearsal_approval(event: event)
    requester = create(:user, :admin)
    authorization = described_class.request!(event: event, buyer_email: "proof@example.com",
      max_amount_cents: 200, expires_at: 1.hour.from_now, actor: requester)

    expect do
      described_class.approve!(authorization: authorization, actor: requester)
    end.to raise_error(described_class::AuthorizationError, /cannot approve/)

    described_class.approve!(authorization: authorization, actor: create(:user, :admin))
    expect(described_class.find_available(event: event, user: requester, buyer_email: "proof@example.com"))
      .to eq(authorization)
    expect do
      LiveMoneyProofAuthorization.transaction(requires_new: true) do
        LiveMoneyProofAuthorization.where(id: authorization.id).update_all(
          revoked_at: Time.current, revocation_reason: nil
        )
      end
    end.to raise_error(ActiveRecord::StatementInvalid, /live_money_authorizations_revocation_valid/)

    order = create(:order, event: event, subtotal_cents: 150, service_fee_cents: 0, total_cents: 150,
      buyer_email: "proof@example.com")
    described_class.claim!(authorization: authorization, order: order, amount_cents: 150,
      user: requester, buyer_email: "proof@example.com")
    expect(authorization.reload).to have_attributes(order_id: order.id, consumed_at: be_present)
    expect(described_class.find_available(event: event, user: requester, buyer_email: "proof@example.com")).to be_nil
  end

  it "rejects public or over-scoped candidates" do
    stub_live_money_provider_ready
    profile = create(:organizer_profile, :payout_ready)
    event = create(:event, :published, organizer_profile: profile, organization: profile.organization,
      title: "Ordinary event", max_capacity: 1, live_money_proof_candidate: true)
    create(:ticket_type, event: event, price_cents: 600, quantity_available: 1, max_per_order: 1, max_per_buyer: 1)

    expect do
      described_class.request!(event: event, buyer_email: "proof@example.com", max_amount_cents: 500,
        expires_at: 1.hour.from_now, actor: create(:user, :admin))
    end.to raise_error(described_class::AuthorizationError, /hidden \[LIVE MONEY TEST\]/)
  end
end
