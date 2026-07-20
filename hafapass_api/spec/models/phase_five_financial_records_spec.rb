# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Phase 5 financial record integrity", type: :model do
  it "keeps posted adjustments and audit logs append-only" do
    adjustment = create(:balance_adjustment)
    audit_log = AuditLogger.record!(action: "test.recorded", auditable: adjustment,
      organization: adjustment.organization)

    expect(adjustment.update(amount_cents: 999)).to be(false)
    expect(adjustment.reload.amount_cents).to eq(100)
    expect(adjustment.destroy).to be(false)
    expect { audit_log.update(action: "test.changed") }.to raise_error(ActiveRecord::ReadonlyAttributeError)
    expect(audit_log.destroy).to be(false)
  end

  it "requires every payout relationship to share one organization" do
    profile = create(:organizer_profile, :verified)
    other_profile = create(:organizer_profile, :verified)
    event = create(:event, :completed, organizer_profile: profile)
    settlement = create(:settlement, organization: profile.organization, event: event)
    other_account = create(:connected_account, organization: other_profile.organization)

    payout = build(:payout, organization: profile.organization, event: event, settlement: settlement,
      connected_account: other_account)
    expect(payout).not_to be_valid
    expect(payout.errors.full_messages).to include(/share an organization/)
  end

  it "rejects negative payable amounts in both the model and database" do
    invalid_settlement = build(:settlement, payable_cents: -1)
    expect(invalid_settlement).not_to be_valid
    expect(invalid_settlement.errors[:payable_cents]).to be_present

    settlement = create(:settlement)
    expect do
      Settlement.where(id: settlement.id).update_all(payable_cents: -1)
    end.to raise_error(ActiveRecord::StatementInvalid, /settlements_payable_nonnegative/)
  end
end
