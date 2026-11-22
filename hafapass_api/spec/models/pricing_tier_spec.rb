require 'rails_helper'

RSpec.describe PricingTier, type: :model do
  describe "validations" do
    it "is valid with valid attributes" do
      tier = build(:pricing_tier)
      expect(tier).to be_valid
    end

    it "requires name" do
      tier = build(:pricing_tier, name: nil)
      expect(tier).not_to be_valid
    end

    it "requires price_cents" do
      tier = build(:pricing_tier, price_cents: nil)
      expect(tier).not_to be_valid
    end

    it "requires tier_type" do
      tier = build(:pricing_tier, tier_type: nil)
      expect(tier).not_to be_valid
    end

    it "requires quantity_limit for quantity_based tiers" do
      tier = build(:pricing_tier, tier_type: :quantity_based, quantity_limit: nil)
      expect(tier).not_to be_valid
    end

    it "does not require quantity_limit for time_based tiers" do
      tier = build(:pricing_tier, :time_based, quantity_limit: nil)
      expect(tier).to be_valid
    end
  end

  describe "time windows" do
    let(:opens) { Time.utc(2027, 4, 1, 0) }
    let(:cutoff) { opens + 1.day }
    let(:closes) { cutoff + 1.day }
    let(:ticket_type) { create(:ticket_type, event: create(:event, starts_at: closes + 1.day), sales_start_at: opens, sales_end_at: closes) }

    it "accepts adjacent windows and rejects a one-second overlap, even with an open boundary" do
      create(:pricing_tier, :time_based, ticket_type: ticket_type, starts_at: nil, ends_at: cutoff)
      next_window = build(:pricing_tier, :time_based, ticket_type: ticket_type, starts_at: cutoff, ends_at: nil)

      expect(next_window).to be_valid
      next_window.starts_at = cutoff - 1.second
      expect(next_window).not_to be_valid
      expect(next_window.errors.full_messages).to include("This price window overlaps another price window")
    end

    it "requires a boundary and a strictly increasing window" do
      tier = build(:pricing_tier, :time_based, ticket_type: ticket_type, starts_at: nil, ends_at: nil)
      expect(tier).not_to be_valid
      expect(tier).not_to be_active

      tier.assign_attributes(starts_at: cutoff, ends_at: cutoff)
      expect(tier).not_to be_valid
      expect(tier.errors.full_messages).to include("The price window must end after it starts")
    end

    it "rejects boundaries outside ticket sales" do
      tier = build(:pricing_tier, :time_based, ticket_type: ticket_type, starts_at: opens - 1.second, ends_at: closes + 1.second)

      expect(tier).not_to be_valid
      expect(tier.errors.full_messages).to contain_exactly(
        "The price window cannot start before ticket sales open", "The price window cannot end after ticket sales close"
      )
    end
  end

  describe "#active?" do
    it "returns true for quantity_based tier with remaining capacity" do
      tier = build(:pricing_tier, tier_type: :quantity_based, quantity_limit: 50, quantity_sold: 10)
      expect(tier.active?).to be true
    end

    it "returns false for quantity_based tier that is sold out" do
      tier = build(:pricing_tier, :sold_out)
      expect(tier.active?).to be false
    end

    it "returns true for time_based tier within date range" do
      tier = build(:pricing_tier, :time_based)
      expect(tier.active?).to be true
    end

    it "returns false for expired time_based tier" do
      tier = build(:pricing_tier, :expired)
      expect(tier.active?).to be false
    end

    it "returns true for time_based tier with only ends_at in the future" do
      tier = build(:pricing_tier, tier_type: :time_based, starts_at: nil, ends_at: 1.week.from_now, quantity_limit: nil)
      expect(tier.active?).to be true
    end
  end

  describe "associations" do
    it "belongs to ticket_type" do
      event = create(:event)
      ticket_type = create(:ticket_type, event: event)
      tier = create(:pricing_tier, ticket_type: ticket_type)
      expect(tier.ticket_type).to eq(ticket_type)
    end
  end
end
