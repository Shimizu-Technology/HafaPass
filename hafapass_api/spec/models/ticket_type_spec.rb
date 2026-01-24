require 'rails_helper'

RSpec.describe TicketType, type: :model do
  describe "validations" do
    it "is valid with valid attributes" do
      ticket_type = build(:ticket_type)
      expect(ticket_type).to be_valid
    end

    it "requires name" do
      ticket_type = build(:ticket_type, name: nil)
      expect(ticket_type).not_to be_valid
      expect(ticket_type.errors[:name]).to include("can't be blank")
    end

    it "requires price_cents" do
      ticket_type = build(:ticket_type, price_cents: nil)
      expect(ticket_type).not_to be_valid
      expect(ticket_type.errors[:price_cents]).to include("can't be blank")
    end

    it "requires price_cents to be non-negative" do
      ticket_type = build(:ticket_type, price_cents: -1)
      expect(ticket_type).not_to be_valid
      expect(ticket_type.errors[:price_cents]).to include("must be greater than or equal to 0")
    end

    it "allows price_cents of 0 (free tickets)" do
      ticket_type = build(:ticket_type, :free)
      expect(ticket_type).to be_valid
    end

    it "requires quantity_available" do
      ticket_type = build(:ticket_type, quantity_available: nil)
      expect(ticket_type).not_to be_valid
      expect(ticket_type.errors[:quantity_available]).to include("can't be blank")
    end

    it "requires quantity_available to be greater than 0" do
      ticket_type = build(:ticket_type, quantity_available: 0)
      expect(ticket_type).not_to be_valid
      expect(ticket_type.errors[:quantity_available]).to include("must be greater than 0")
    end
  end

  describe "#sold_out?" do
    it "returns false when tickets are available" do
      ticket_type = build(:ticket_type, quantity_available: 100, quantity_sold: 50)
      expect(ticket_type.sold_out?).to be false
    end

    it "returns true when quantity_sold equals quantity_available" do
      ticket_type = build(:ticket_type, :sold_out)
      expect(ticket_type.sold_out?).to be true
    end

    it "returns true when quantity_sold exceeds quantity_available" do
      ticket_type = build(:ticket_type, quantity_available: 10, quantity_sold: 11)
      expect(ticket_type.sold_out?).to be true
    end

    it "returns false when no tickets are sold" do
      ticket_type = build(:ticket_type, quantity_available: 100, quantity_sold: 0)
      expect(ticket_type.sold_out?).to be false
    end
  end

  describe "#available_quantity" do
    it "returns the difference between available and sold" do
      ticket_type = build(:ticket_type, quantity_available: 100, quantity_sold: 30)
      expect(ticket_type.available_quantity).to eq(70)
    end

    it "returns 0 when sold out" do
      ticket_type = build(:ticket_type, :sold_out)
      expect(ticket_type.available_quantity).to eq(0)
    end

    it "returns full quantity when none sold" do
      ticket_type = build(:ticket_type, quantity_available: 50, quantity_sold: 0)
      expect(ticket_type.available_quantity).to eq(50)
    end
  end

  describe "associations" do
    it "belongs to event" do
      event = create(:event)
      ticket_type = create(:ticket_type, event: event)
      expect(ticket_type.event).to eq(event)
    end

    it "has many tickets" do
      event = create(:event, :published)
      ticket_type = create(:ticket_type, event: event)
      order = create(:order, event: event)
      ticket = create(:ticket, order: order, ticket_type: ticket_type, event: event)
      expect(ticket_type.tickets).to include(ticket)
    end
  end

  describe "defaults" do
    it "defaults quantity_sold to 0" do
      event = create(:event)
      ticket_type = TicketType.create!(name: "Test", price_cents: 1000, quantity_available: 50, event: event)
      expect(ticket_type.quantity_sold).to eq(0)
    end
  end
end
