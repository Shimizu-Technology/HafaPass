# frozen_string_literal: true

require "rails_helper"

RSpec.describe PayoutReserves do
  include ActiveSupport::Testing::TimeHelpers

  let(:admin) { create(:user, :admin) }
  let(:profile) { create(:organizer_profile, :verified) }
  let(:organization) { profile.organization }
  let(:event) do
    create(:event, :completed, organization: organization, organizer_profile: profile,
      starts_at: guam(2027, 1, 30, 9), ends_at: guam(2027, 1, 30, 18))
  end
  let(:ticket_type) { create(:ticket_type, event: event, price_cents: 1700) }

  around do |example|
    example.metadata[:own_clock] ? example.run : travel_to(guam(2027, 2, 1, 10)) { example.run }
  end

  it "holds 10% of platform-held net proceeds, rounded half up, and dates its release in Guam" do
    # 7 × $17.00 − $3.95 processing = $115.05 → $11.505 → $11.51.
    record_card_sale!(event, ticket_type: ticket_type, quantity: 7, processing_fee_cents: 395)
    hold = described_class.hold!(event: event, actor: admin)
    expect(hold).to have_attributes(kind: "reserve_hold", amount_cents: -1151, event: event, status: "posted")
    expect(hold.reason).to eq("Chargeback reserve: 10% of $115.05 net proceeds held by HåfaPass, held until 2027-03-01")
    audit = AuditLog.find_by!(auditable: hold, action: "balance_adjustment.posted")
    expect(audit.metadata).to include("reserve_rate_bps" => 1000, "net_before_reserve_cents" => 11_505,
      "suggested_reserve_cents" => 1151, "release_on" => "2027-03-01", "source" => "payout_schedule")
    expect(Settlements::Calculator.call(event).attributes).to include(reserve_cents: 1151, payable_cents: 11_505 - 1151)
  end

  it "accepts an administrator's amount within the net proceeds and records that it was overridden" do
    record_card_sale!(event, ticket_type: ticket_type, quantity: 2, processing_fee_cents: 100)
    hold = described_class.hold!(event: event, actor: admin, amount_cents: "500", note: "Higher risk first event")
    expect(hold.amount_cents).to eq(-500)
    expect(hold.reason).to include("15.15%", "Higher risk first event")
    expect(AuditLog.find_by!(auditable: hold).metadata).to include("amount_overridden" => true)
    expect { described_class.hold!(event: event, actor: admin) }.to raise_error(described_class::ReserveError, /already held/)
    other = create(:event, :completed, organization: organization, organizer_profile: profile)
    record_card_sale!(other, ticket_type: create(:ticket_type, event: other, price_cents: 1000), processing_fee_cents: 30)
    expect { described_class.hold!(event: other, actor: admin, amount_cents: 971) }
      .to raise_error(described_class::ReserveError, "Reserve cannot be more than the event's net proceeds held by HåfaPass")
    expect { described_class.hold!(event: other, actor: admin, amount_cents: "1.5") }
      .to raise_error(described_class::ReserveError, "Reserve must be whole cents")
  end

  it "refuses non-admins, unfinished events, zero proceeds and events already paid" do
    record_card_sale!(event, ticket_type: ticket_type, quantity: 1, processing_fee_cents: 50)
    expect { described_class.hold!(event: event, actor: profile.user) }
      .to raise_error(described_class::ReserveError, "Administrator access is required")
    published = create(:event, :published, organization: organization, organizer_profile: profile)
    expect { described_class.hold!(event: published, actor: admin) }
      .to raise_error(described_class::ReserveError, "Complete the event before holding its reserve")
    empty = create(:event, :completed, organization: organization, organizer_profile: profile)
    expect { described_class.hold!(event: empty, actor: admin) }
      .to raise_error(described_class::ReserveError, "There are no platform-held proceeds to reserve")
    expect { described_class.release!(event: empty, actor: admin) }
      .to raise_error(described_class::ReserveError, "No reserve is held for this event")
    account = create(:connected_account, organization: organization, provider: "manual", with_readiness_approval: false)
    create(:payout, organization: organization, event: event, connected_account: account, status: :paid,
      provider_payout_id: "TRF-EARLIER")
    expect { described_class.hold!(event: event, actor: admin) }
      .to raise_error(described_class::ReserveError, /already has a payout requested or sent/)
    expect(BalanceAdjustment.count).to eq(0)
  end

  it "releases the whole held reserve after 30 days; a chargeback in the window reduces what is then owed", :own_clock do
    travel_to(guam(2027, 2, 1, 10)) do
      # 20 × $17.00 − $2.00 processing = $338.00; $33.80 held.
      order, _item, capture = record_card_sale!(event, ticket_type: ticket_type, quantity: 10, processing_fee_cents: 100)
      record_card_sale!(event, ticket_type: ticket_type, quantity: 10, processing_fee_cents: 100)
      described_class.hold!(event: event, actor: admin)
      expect(PayoutSchedule.for(event).reserve_held_cents).to eq(3380)
      record_lost_chargeback!(order, capture, amount_cents: 1800)
      expect(PayoutSchedule.for(event).owed_cents).to eq(33_800 - 3380 - 1800)
    end
    travel_to(guam(2027, 2, 28, 23, 59)) do
      expect { described_class.release!(event: event, actor: admin) }
        .to raise_error(described_class::ReserveError, /held until 2027-03-01/)
    end
    # Midnight in Guam is still Feb 28 in UTC: the Guam date governs.
    travel_to(guam(2027, 3, 1, 0, 5)) do
      expect(Time.current.utc.to_date).to eq(Date.new(2027, 2, 28))
      release = described_class.release!(event: event, actor: admin)
      expect(release).to have_attributes(kind: "reserve_release", amount_cents: 3380)
      after = PayoutSchedule.for(event)
      expect(after.reserve_held_cents).to eq(0)
      expect(after.reserve_released_cents).to eq(3380)
      expect(after.owed_cents).to eq(33_800 - 1800)
      expect { described_class.release!(event: event, actor: admin) }
        .to raise_error(described_class::ReserveError, "No reserve is held for this event")
    end
  end

  # Policy point from the #241 agreement cross-check: about 10% of the net
  # proceeds HåfaPass holds. Door cash and organizer-direct card sales (Clover
  # on the organizer's own merchant account) are not held, so not reserved.
  it "bases the reserve on custodial proceeds only: $100 Stripe + $40 Clover + $20 door cash holds $10" do
    stripe_type = create(:ticket_type, event: event, name: "Online", price_cents: 10_000)
    record_card_sale!(event, ticket_type: stripe_type, quantity: 1, buyer_fee_cents: 0, processing_fee_cents: 320,
      bearer: "platform")
    clover_type = create(:ticket_type, event: event, name: "Door card", price_cents: 4000)
    clover = create(:order, event: event, source: "box_office", payment_method: "door_card", subtotal_cents: 4000,
      service_fee_cents: 0, total_cents: 4000)
    create(:order_item, order: clover, ticket_type: clover_type, unit_price_cents: 4000, fee_cents: 0,
      organizer_proceeds_cents: 4000)
    create(:payment, :succeeded, order: clover, provider: "boh_clover", amount_cents: 4000, provider_environment: "live")
    cash_type = create(:ticket_type, event: event, name: "Door cash", price_cents: 2000)
    cash = create(:order, event: event, source: "box_office", payment_method: "door_cash", subtotal_cents: 2000,
      service_fee_cents: 0, total_cents: 2000)
    create(:order_item, order: cash, ticket_type: cash_type, unit_price_cents: 2000, fee_cents: 0,
      organizer_proceeds_cents: 2000)

    schedule = PayoutSchedule.for(event)
    expect(schedule.net_before_reserve_cents).to eq(14_000)
    expect(schedule.organizer_direct_card_cents).to eq(4000)
    expect(schedule.custodial_net_cents).to eq(10_000)
    expect(schedule.suggested_reserve_cents).to eq(1000)
    hold = described_class.hold!(event: event, actor: admin)
    expect(hold.amount_cents).to eq(-1000)
    expect(hold.reason).to start_with("Chargeback reserve: 10% of $100.00 net proceeds held by HåfaPass")
    expect(AuditLog.find_by!(auditable: hold).metadata).to include("custodial_net_cents" => 10_000,
      "organizer_direct_card_cents" => 4000, "net_before_reserve_cents" => 14_000)
    expect { described_class.hold!(event: create(:event, :completed, organization: organization, organizer_profile: profile), actor: admin) }
      .to raise_error(described_class::ReserveError, "There are no platform-held proceeds to reserve")

    statement = PayoutStatement.call(event: event)
    reserve_line = statement[:sections].last[:lines].find { |line| line[:label] == "Reserve held" }
    expect(reserve_line[:note]).to include("about 10% of the net proceeds HåfaPass holds for you")
    expect(statement[:notes]).to include("Card sales on your own terminal ($40.00) are paid to you by your card processor, " \
      "so no chargeback reserve is held on them.")
    expect(statement[:notes]).to include("Door cash ($20.00) stays with you and is not included in any bank transfer.")
  end

  it "keeps a tax identifier out of an early-release reason" do
    record_card_sale!(event, ticket_type: ticket_type, quantity: 2, processing_fee_cents: 50)
    described_class.hold!(event: event, actor: admin)
    expect { described_class.release!(event: event, actor: admin, early_release_reason: "Approved for 123-45-6789 payee") }
      .to raise_error(described_class::ReserveError, BackupWithholding::TIN_WARNING)
  end
end
