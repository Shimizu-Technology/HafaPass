require 'rails_helper'

RSpec.describe Event, type: :model do
  describe "validations" do
    it "is valid with valid attributes" do
      event = build(:event)
      expect(event).to be_valid
    end

    it "requires title" do
      event = build(:event, title: nil)
      expect(event).not_to be_valid
      expect(event.errors[:title]).to include("can't be blank")
    end

    it "requires slug to be unique" do
      create(:event, title: "Same Title")
      event = build(:event, title: "Same Title", slug: nil)
      # Slug should be auto-generated with suffix to avoid conflict
      expect(event).to be_valid
    end
  end

  describe "slug generation" do
    it "generates slug from title on create" do
      event = create(:event, title: "Full Moon Party")
      expect(event.slug).to eq("full-moon-party")
    end

    it "parameterizes the title for slug" do
      event = create(:event, title: "Summer Night's Special Event!")
      expect(event.slug).to match(/\Asummer-night-s-special-event/)
    end

    it "appends hex suffix when slug already exists" do
      create(:event, title: "Beach Party", slug: "beach-party")
      event = create(:event, title: "Beach Party")
      expect(event.slug).to match(/\Abeach-party-[a-f0-9]{6}\z/)
    end

    it "does not change slug if title has not changed" do
      event = create(:event, title: "My Event")
      original_slug = event.slug
      event.update!(description: "Updated description")
      expect(event.slug).to eq(original_slug)
    end

    it "regenerates slug when title changes" do
      event = create(:event, title: "Original Title")
      event.update!(title: "New Title")
      expect(event.slug).to eq("new-title")
    end
  end

  describe "status enum" do
    it "defaults to draft" do
      event = Event.new
      expect(event.draft?).to be true
    end

    it "can be published" do
      event = create(:event, :published)
      expect(event.published?).to be true
    end

    it "can be cancelled" do
      event = create(:event, :cancelled)
      expect(event.cancelled?).to be true
    end

    it "can be completed" do
      event = create(:event, :completed)
      expect(event.completed?).to be true
    end
  end

  describe "category enum" do
    it "supports nightlife" do
      event = build(:event, category: :nightlife)
      expect(event.nightlife?).to be true
    end

    it "supports concert" do
      event = build(:event, category: :concert)
      expect(event.concert?).to be true
    end

    it "supports festival" do
      event = build(:event, category: :festival)
      expect(event.festival?).to be true
    end

    it "supports dining" do
      event = build(:event, category: :dining)
      expect(event.dining?).to be true
    end

    it "supports sports" do
      event = build(:event, category: :sports)
      expect(event.sports?).to be true
    end

    it "supports other" do
      event = build(:event, category: :other)
      expect(event.other?).to be true
    end
  end

  describe "age_restriction enum" do
    it "supports all_ages" do
      event = build(:event, age_restriction: :all_ages)
      expect(event.all_ages?).to be true
    end

    it "supports eighteen_plus" do
      event = build(:event, age_restriction: :eighteen_plus)
      expect(event.eighteen_plus?).to be true
    end

    it "supports twenty_one_plus" do
      event = build(:event, age_restriction: :twenty_one_plus)
      expect(event.twenty_one_plus?).to be true
    end
  end

  describe "scopes" do
    let!(:published_upcoming) { create(:event, :published, starts_at: 7.days.from_now) }
    let!(:published_past) { create(:event, :published, starts_at: 7.days.ago) }
    let!(:draft_event) { create(:event, status: :draft, starts_at: 7.days.from_now) }
    let!(:featured_event) { create(:event, :published, :featured, starts_at: 3.days.from_now) }

    describe ".published" do
      it "returns only published events" do
        expect(Event.published).to include(published_upcoming, published_past, featured_event)
        expect(Event.published).not_to include(draft_event)
      end
    end

    describe ".upcoming" do
      it "returns events with starts_at in the future" do
        expect(Event.upcoming).to include(published_upcoming, draft_event, featured_event)
        expect(Event.upcoming).not_to include(published_past)
      end
    end

    describe ".past" do
      it "returns events with starts_at in the past" do
        expect(Event.past).to include(published_past)
        expect(Event.past).not_to include(published_upcoming, draft_event, featured_event)
      end
    end

    describe ".featured" do
      it "returns only featured events" do
        expect(Event.featured).to include(featured_event)
        expect(Event.featured).not_to include(published_upcoming, published_past, draft_event)
      end
    end

    it "chains scopes correctly" do
      results = Event.published.upcoming
      expect(results).to include(published_upcoming, featured_event)
      expect(results).not_to include(published_past, draft_event)
    end
  end

  describe "associations" do
    it "belongs to organizer_profile" do
      profile = create(:organizer_profile)
      event = create(:event, organizer_profile: profile)
      expect(event.organizer_profile).to eq(profile)
    end

    it "has many ticket_types" do
      event = create(:event)
      ticket_type = create(:ticket_type, event: event)
      expect(event.ticket_types).to include(ticket_type)
    end

    it "has many orders" do
      event = create(:event, :published)
      order = create(:order, event: event)
      expect(event.orders).to include(order)
    end

    it "has many tickets" do
      event = create(:event, :published)
      ticket_type = create(:ticket_type, event: event)
      order = create(:order, event: event)
      ticket = create(:ticket, order: order, ticket_type: ticket_type, event: event)
      expect(event.tickets).to include(ticket)
    end

    it "destroys ticket_types when destroyed" do
      event = create(:event)
      create(:ticket_type, event: event)
      expect { event.destroy }.to change(TicketType, :count).by(-1)
    end
  end
end
