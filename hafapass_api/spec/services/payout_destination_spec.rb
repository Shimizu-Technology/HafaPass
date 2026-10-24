# frozen_string_literal: true

require "rails_helper"

RSpec.describe "PayoutCreator selected destination" do
  let(:profile) { create(:organizer_profile, :verified) }
  let(:organization) { profile.organization }
  let(:actor) { profile.user }
  let(:event) { create(:event, :completed, organizer_profile: profile) }
  let(:check_details) { { "payee_name" => "Island Events LLC", "delivery_method" => "pickup" } }

  [%w[paypal check], %w[check paypal]].each do |order|
    it "reserves exactly the selected check with creation order #{order.join(', ')}" do
      accounts = order.to_h do |provider|
        [provider, create(:connected_account, organization: organization, provider: provider,
          payout_details: provider == "check" ? check_details : {})]
      end
      ConnectedAccounts::Manager.select!(account: accounts.fetch("check"), actor: actor)
      create(:balance_adjustment, organization: organization, event: event, amount_cents: 1000)
      settlement = Settlements::Finalizer.call(event: event, actor: actor)
      creator = PayoutCreator.new(settlement: settlement, actor: actor, idempotency_key: "selected-destination")
      payout, reserved = creator.send(:reserve!)
      expect(reserved).to be(true)
      expect(payout.connected_account).to eq(accounts.fetch("check"))
      expect(payout.provider).to eq("check")
      expect(payout.payee_snapshot).to eq(check_details)
    end
  end

  it "does not fall back when a selected bank is blocked, including the withholding path" do
    create(:connected_account, organization: organization)
    bank = create(:connected_account, organization: organization, provider: "manual")
    organization.update!(payout_connected_account: bank)
    create(:balance_adjustment, organization: organization, event: event, amount_cents: 1000)
    settlement = Settlements::Finalizer.call(event: event, actor: actor)
    organization.organizer_tax_information.update!(backup_withholding_flag: true, backup_withholding_reason: "Review notice")
    creator = PayoutCreator.new(settlement: settlement, actor: actor, idempotency_key: "blocked-bank")
    expect { creator.send(:reserve!) }.to raise_error(PayoutCreator::PayoutError, /payout-ready connected account/)
    expect(organization.payouts).to be_empty
  end
end
