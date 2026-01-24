require 'rails_helper'

RSpec.describe Ticket, type: :model do
  describe "#generate_qr_code!" do
    it "generates a UUID qr_code on create" do
      event = create(:event, :published)
      ticket_type = create(:ticket_type, event: event)
      order = create(:order, event: event)
      ticket = create(:ticket, order: order, ticket_type: ticket_type, event: event)
      expect(ticket.qr_code).to be_present
      expect(ticket.qr_code).to match(/\A[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\z/)
    end

    it "generates unique qr_codes for different tickets" do
      event = create(:event, :published)
      ticket_type = create(:ticket_type, event: event)
      order = create(:order, event: event)
      ticket1 = create(:ticket, order: order, ticket_type: ticket_type, event: event)
      ticket2 = create(:ticket, order: order, ticket_type: ticket_type, event: event)
      expect(ticket1.qr_code).not_to eq(ticket2.qr_code)
    end
  end

  describe "#check_in!" do
    it "updates status to checked_in" do
      event = create(:event, :published)
      ticket_type = create(:ticket_type, event: event)
      order = create(:order, event: event)
      ticket = create(:ticket, order: order, ticket_type: ticket_type, event: event, status: :issued)
      ticket.check_in!
      expect(ticket.reload.checked_in?).to be true
    end

    it "sets checked_in_at timestamp" do
      event = create(:event, :published)
      ticket_type = create(:ticket_type, event: event)
      order = create(:order, event: event)
      ticket = create(:ticket, order: order, ticket_type: ticket_type, event: event, status: :issued)
      ticket.check_in!
      expect(ticket.reload.checked_in_at).to be_within(2.seconds).of(Time.current)
    end

    it "raises error if ticket is already checked in" do
      event = create(:event, :published)
      ticket_type = create(:ticket_type, event: event)
      order = create(:order, event: event)
      ticket = create(:ticket, order: order, ticket_type: ticket_type, event: event,
                       status: :checked_in, checked_in_at: 1.hour.ago)
      expect { ticket.check_in! }.to raise_error(RuntimeError, "Ticket is not in issued status")
    end

    it "raises error if ticket is cancelled" do
      event = create(:event, :published)
      ticket_type = create(:ticket_type, event: event)
      order = create(:order, event: event)
      ticket = create(:ticket, order: order, ticket_type: ticket_type, event: event, status: :cancelled)
      expect { ticket.check_in! }.to raise_error(RuntimeError, "Ticket is not in issued status")
    end

    it "raises error if ticket is transferred" do
      event = create(:event, :published)
      ticket_type = create(:ticket_type, event: event)
      order = create(:order, event: event)
      ticket = create(:ticket, order: order, ticket_type: ticket_type, event: event, status: :transferred)
      expect { ticket.check_in! }.to raise_error(RuntimeError, "Ticket is not in issued status")
    end
  end

  describe "set_attendee_info callback" do
    it "copies buyer info from order when attendee info not set" do
      event = create(:event, :published)
      ticket_type = create(:ticket_type, event: event)
      order = create(:order, event: event, buyer_name: "Jane Doe", buyer_email: "jane@example.com")
      ticket = create(:ticket, order: order, ticket_type: ticket_type, event: event,
                       attendee_name: nil, attendee_email: nil)
      expect(ticket.attendee_name).to eq("Jane Doe")
      expect(ticket.attendee_email).to eq("jane@example.com")
    end

    it "preserves explicit attendee info when provided" do
      event = create(:event, :published)
      ticket_type = create(:ticket_type, event: event)
      order = create(:order, event: event, buyer_name: "Jane Doe", buyer_email: "jane@example.com")
      ticket = create(:ticket, order: order, ticket_type: ticket_type, event: event,
                       attendee_name: "Bob Smith", attendee_email: "bob@example.com")
      expect(ticket.attendee_name).to eq("Bob Smith")
      expect(ticket.attendee_email).to eq("bob@example.com")
    end
  end

  describe "status enum" do
    it "defaults to issued" do
      event = create(:event, :published)
      ticket_type = create(:ticket_type, event: event)
      order = create(:order, event: event)
      ticket = create(:ticket, order: order, ticket_type: ticket_type, event: event)
      expect(ticket.issued?).to be true
    end

    it "can be checked_in" do
      event = create(:event, :published)
      ticket_type = create(:ticket_type, event: event)
      order = create(:order, event: event)
      ticket = create(:ticket, order: order, ticket_type: ticket_type, event: event,
                       status: :checked_in, checked_in_at: Time.current)
      expect(ticket.checked_in?).to be true
    end

    it "can be cancelled" do
      event = create(:event, :published)
      ticket_type = create(:ticket_type, event: event)
      order = create(:order, event: event)
      ticket = create(:ticket, order: order, ticket_type: ticket_type, event: event, status: :cancelled)
      expect(ticket.cancelled?).to be true
    end

    it "can be transferred" do
      event = create(:event, :published)
      ticket_type = create(:ticket_type, event: event)
      order = create(:order, event: event)
      ticket = create(:ticket, order: order, ticket_type: ticket_type, event: event, status: :transferred)
      expect(ticket.transferred?).to be true
    end
  end

  describe "associations" do
    it "belongs to order" do
      event = create(:event, :published)
      ticket_type = create(:ticket_type, event: event)
      order = create(:order, event: event)
      ticket = create(:ticket, order: order, ticket_type: ticket_type, event: event)
      expect(ticket.order).to eq(order)
    end

    it "belongs to ticket_type" do
      event = create(:event, :published)
      ticket_type = create(:ticket_type, event: event)
      order = create(:order, event: event)
      ticket = create(:ticket, order: order, ticket_type: ticket_type, event: event)
      expect(ticket.ticket_type).to eq(ticket_type)
    end

    it "belongs to event" do
      event = create(:event, :published)
      ticket_type = create(:ticket_type, event: event)
      order = create(:order, event: event)
      ticket = create(:ticket, order: order, ticket_type: ticket_type, event: event)
      expect(ticket.event).to eq(event)
    end
  end

  describe "qr_code uniqueness" do
    it "validates qr_code uniqueness" do
      event = create(:event, :published)
      ticket_type = create(:ticket_type, event: event)
      order = create(:order, event: event)
      ticket1 = create(:ticket, order: order, ticket_type: ticket_type, event: event)
      ticket2 = build(:ticket, order: order, ticket_type: ticket_type, event: event, qr_code: ticket1.qr_code)
      expect(ticket2).not_to be_valid
      expect(ticket2.errors[:qr_code]).to include("has already been taken")
    end
  end
end
