require "rails_helper"

RSpec.describe WaitlistEntry, type: :model do
  let(:organizer_profile) { create(:organizer_profile) }
  let(:event) { create(:event, organizer_profile: organizer_profile, status: :published) }
  let(:ticket_type) { create(:ticket_type, event: event) }

  describe "validations" do
    it "requires email" do
      entry = WaitlistEntry.new(event: event, quantity: 1)
      expect(entry).not_to be_valid
      expect(entry.errors[:email]).to be_present
    end

    it "validates email format" do
      entry = WaitlistEntry.new(event: event, email: "not-an-email", quantity: 1)
      expect(entry).not_to be_valid
    end

    it "validates quantity range" do
      entry = WaitlistEntry.new(event: event, email: "test@example.com", quantity: 0)
      expect(entry).not_to be_valid

      entry.quantity = 11
      expect(entry).not_to be_valid

      entry.quantity = 5
      entry.valid?
      expect(entry.errors[:quantity]).to be_empty
    end

    it "enforces uniqueness per event + ticket_type + email" do
      WaitlistEntry.transaction do
        WaitlistEntry.create!(event: event, ticket_type: ticket_type, email: "dupe@test.com", quantity: 1)
      end
      duplicate = WaitlistEntry.new(event: event, ticket_type: ticket_type, email: "dupe@test.com", quantity: 1)
      expect(duplicate).not_to be_valid
      expect(duplicate.errors[:email]).to include("is already on the waitlist for this ticket type")
    end
  end

  describe "#assign_position" do
    it "auto-assigns incrementing positions" do
      entry1 = WaitlistEntry.transaction { WaitlistEntry.create!(event: event, email: "a@test.com", quantity: 1) }
      entry2 = WaitlistEntry.transaction { WaitlistEntry.create!(event: event, email: "b@test.com", quantity: 1) }
      entry3 = WaitlistEntry.transaction { WaitlistEntry.create!(event: event, email: "c@test.com", quantity: 1) }

      expect(entry1.position).to eq(1)
      expect(entry2.position).to eq(2)
      expect(entry3.position).to eq(3)
    end

    it "assigns positions independently per ticket type" do
      entry1 = WaitlistEntry.transaction { WaitlistEntry.create!(event: event, ticket_type: ticket_type, email: "a@test.com", quantity: 1) }
      entry2 = WaitlistEntry.transaction { WaitlistEntry.create!(event: event, ticket_type: nil, email: "b@test.com", quantity: 1) }

      expect(entry1.position).to eq(1)
      expect(entry2.position).to eq(1)
    end
  end

  describe "#notify!" do
    it "updates status, notified_at, and expires_at" do
      entry = WaitlistEntry.transaction { WaitlistEntry.create!(event: event, email: "notify@test.com", quantity: 1) }
      expect(entry.status).to eq("waiting")

      entry.notify!

      expect(entry.status).to eq("notified")
      expect(entry.notified_at).to be_present
      expect(entry.expires_at).to be > Time.current
      expect(entry.expires_at).to be < 25.hours.from_now
    end
  end

  describe "#offer_expired?" do
    it "returns false when no expires_at" do
      entry = WaitlistEntry.transaction { WaitlistEntry.create!(event: event, email: "test@test.com", quantity: 1) }
      expect(entry.offer_expired?).to be false
    end

    it "returns true when expires_at is in the past" do
      entry = WaitlistEntry.transaction { WaitlistEntry.create!(event: event, email: "test@test.com", quantity: 1) }
      entry.update!(status: :notified, expires_at: 1.hour.ago)
      expect(entry.offer_expired?).to be true
    end

    it "returns false when converted even if expired" do
      entry = WaitlistEntry.transaction { WaitlistEntry.create!(event: event, email: "test@test.com", quantity: 1) }
      entry.update!(status: :converted, expires_at: 1.hour.ago)
      expect(entry.offer_expired?).to be false
    end
  end
end
