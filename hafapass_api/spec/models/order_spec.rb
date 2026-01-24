require 'rails_helper'

RSpec.describe Order, type: :model do
  describe "validations" do
    it "is valid with valid attributes" do
      order = build(:order)
      expect(order).to be_valid
    end

    it "requires buyer_email" do
      order = build(:order, buyer_email: nil)
      expect(order).not_to be_valid
      expect(order.errors[:buyer_email]).to include("can't be blank")
    end

    it "requires buyer_name" do
      order = build(:order, buyer_name: nil)
      expect(order).not_to be_valid
      expect(order.errors[:buyer_name]).to include("can't be blank")
    end

    it "allows user to be nil (guest checkout)" do
      order = build(:order, user: nil)
      expect(order).to be_valid
    end
  end

  describe "status enum" do
    it "defaults to pending for new records" do
      event = create(:event, :published)
      order = Order.new(event: event, buyer_email: "test@example.com", buyer_name: "Test")
      expect(order.pending?).to be true
    end

    it "can be completed" do
      order = build(:order, status: :completed)
      expect(order.completed?).to be true
    end

    it "can be refunded" do
      order = build(:order, :refunded)
      expect(order.refunded?).to be true
    end

    it "can be cancelled" do
      order = build(:order, :cancelled)
      expect(order.cancelled?).to be true
    end

    it "provides status query methods" do
      order = build(:order, status: :completed)
      expect(order.completed?).to be true
      expect(order.pending?).to be false
      expect(order.refunded?).to be false
      expect(order.cancelled?).to be false
    end
  end

  describe "associations" do
    it "belongs to event" do
      event = create(:event, :published)
      order = create(:order, event: event)
      expect(order.event).to eq(event)
    end

    it "optionally belongs to user" do
      user = create(:user)
      event = create(:event, :published)
      order = create(:order, user: user, event: event)
      expect(order.user).to eq(user)
    end

    it "has many tickets" do
      event = create(:event, :published)
      ticket_type = create(:ticket_type, event: event)
      order = create(:order, event: event)
      ticket = create(:ticket, order: order, ticket_type: ticket_type, event: event)
      expect(order.tickets).to include(ticket)
    end

    it "destroys tickets when destroyed" do
      event = create(:event, :published)
      ticket_type = create(:ticket_type, event: event)
      order = create(:order, event: event)
      create(:ticket, order: order, ticket_type: ticket_type, event: event)
      expect { order.destroy }.to change(Ticket, :count).by(-1)
    end
  end
end
