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
