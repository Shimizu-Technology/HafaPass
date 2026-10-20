require "rails_helper"

RSpec.describe PublicSlug do
  describe "event links" do
    it "follows title edits while the event is a draft" do
      event = create(:event, title: "Original Title")

      event.update!(title: "New Title")

      expect(event.slug).to eq("new-title")
      expect(event.slug_redirects).to be_empty
    end

    it "keeps the link of a published event when the title changes" do
      event = create(:event, :published, title: "Full Moon Party")

      event.update!(title: "Full Moon Party: Encore")

      expect(event.reload.slug).to eq("full-moon-party")
    end

    it "keeps the link once the event was ever public, even after it is archived" do
      event = create(:event, title: "Old Show", status: :completed, published_at: 2.days.ago)
      event.update_columns(status: Event.statuses[:archived])

      event.reload.update!(title: "Renamed Show")

      expect(event.slug).to eq("old-show")
    end

    it "treats a publish in the state history as public even without published_at" do
      event = create(:event, title: "Legacy Show")
      event.event_state_changes.create!(actor_user: create(:user), action: "publish", from_status: "draft",
        to_status: "published", occurred_at: 1.day.ago)
      event.update_columns(status: Event.statuses[:archived])

      event.reload.update!(title: "Legacy Show Renamed")

      expect(event.slug).to eq("legacy-show")
    end

    it "stops a draft's link from following the title once a link name is chosen" do
      event = create(:event, title: "Draft Night")
      event.update!(slug: "My-Night ")

      event.update!(title: "Something Else")

      expect(event.slug).to eq("my-night")
      expect(event.custom_slug).to be(true)
    end

    it "retires the old link of a published event when a new link is chosen" do
      event = create(:event, :published, title: "Island Fest")

      event.update!(slug: "island-fest-2026")

      expect(event.slug_redirects.pluck(:slug)).to eq(["island-fest"])
      expect(Event.find_by_public_slug("island-fest")).to eq(event)
      expect(Event.find_by_public_slug("island-fest-2026")).to eq(event)
    end

    it "lets an event take back one of its own retired links" do
      event = create(:event, :published, title: "Island Fest")
      event.update!(slug: "island-fest-2026")

      event.update!(slug: "island-fest")

      expect(event.slug_redirects.pluck(:slug)).to eq(["island-fest-2026"])
      expect(Event.find_by_public_slug("island-fest-2026")).to eq(event)
    end

    it "does not record history for a draft's link changes" do
      event = create(:event, title: "Draft Night")

      event.update!(slug: "draft-night-two")

      expect(event.slug_redirects).to be_empty
    end

    it "rejects a link another event uses now or used before" do
      first = create(:event, :published, title: "Island Fest")
      first.update!(slug: "island-fest-2026")
      second = create(:event, :published, title: "Other Fest")

      expect(second.update(slug: "island-fest")).to be(false)
      expect(second.errors.full_messages).to include("Event link is already used by another event")
      expect(second.update(slug: "island-fest-2026")).to be(false)
      expect(second.errors.full_messages).to include("Event link is already used by another event")
    end

    it "rejects reserved words, bad characters and bad lengths" do
      event = create(:event, :published)

      %w[admin checkout new hafapass].each do |word|
        expect(event.update(slug: word)).to be(false)
        expect(event.errors.full_messages).to include("Event link is reserved. Choose a different link name")
      end
      expect(event.update(slug: "fun_night!")).to be(false)
      expect(event.errors.full_messages.first).to match(/lowercase letters, numbers, and single hyphens/)
      expect(event.update(slug: "-fun--night-")).to be(false)
      expect(event.update(slug: "ab")).to be(false)
      expect(event.errors.full_messages).to include("Event link must be between 3 and 80 characters")
      expect(event.update(slug: "a" * 81)).to be(false)
    end

    it "does not hand a retired link to a new event with the same title" do
      event = create(:event, :published, title: "Island Fest")
      event.update!(slug: "island-fest-2026")

      newcomer = create(:event, title: "Island Fest")

      expect(newcomer.slug).to match(/\Aisland-fest-[a-f0-9]{6}\z/)
    end

    it "generates links that follow the format rules" do
      expect(create(:event, title: "Admin").slug).to match(/\Aadmin-[a-f0-9]{6}\z/)
      expect(create(:event, title: "DJ").slug).to match(/\Adj-[a-f0-9]{6}\z/)
      expect(create(:event, title: "マツリ").slug).to match(/\Aevent(-[a-f0-9]{6})?\z/)
      expect(create(:event, title: "Snake_case Party").slug).to eq("snake-case-party")
      expect(create(:event, title: "A" * 120).slug.length).to be <= PublicSlug::LENGTH.max
    end

    it "does not treat a generated link as chosen when validation runs twice" do
      event = build(:event, title: "Twice Validated")
      event.valid?

      event.save!

      expect(event.custom_slug).to be(false)
      event.update!(title: "Still A Draft")
      expect(event.slug).to eq("still-a-draft")
    end

    it "finds events by links typed in the wrong case, preferring an exact legacy match" do
      event = create(:event, :published, title: "Summer Jam")
      event.update!(slug: "summer-jam-2026")
      legacy = create(:event, :published)
      legacy.update_columns(slug: "Legacy_Link")

      expect(Event.find_by_public_slug(" Summer-Jam-2026 ")).to eq(event)
      expect(Event.find_by_public_slug("SUMMER-JAM")).to eq(event)
      expect(Event.find_by_public_slug("Legacy_Link")).to eq(legacy)
    end

    it "leaves legacy links that break the new rules alone until someone changes them" do
      event = create(:event, :published)
      event.update_columns(slug: "Legacy_Link")

      expect(event.reload.update(title: "Fresh title")).to be(true)
      expect(event.slug).to eq("Legacy_Link")
    end
  end

  describe "venue links" do
    it "keeps the link when a venue is renamed" do
      venue = create(:venue, name: "Tumon Hall", slug: nil)
      expect(venue.slug).to eq("tumon-hall")

      venue.update!(name: "Tumon Grand Hall")

      expect(venue.reload.slug).to eq("tumon-hall")
    end

    it "retires the old link when an admin chooses a new one" do
      venue = create(:venue, name: "Tumon Hall", slug: nil)

      venue.update!(slug: "tumon-grand-hall")

      expect(venue.slug_redirects.pluck(:slug)).to eq(["tumon-hall"])
      expect(Venue.find_by_public_slug("tumon-hall")).to eq(venue)
      expect(create(:venue, name: "Tumon Hall", slug: nil).slug).to match(/\Atumon-hall-[a-f0-9]{6}\z/)
    end

    it "deletes retired links along with the venue" do
      venue = create(:venue, name: "Pop-up Hall", slug: nil)
      venue.update!(slug: "pop-up-hall-2026")

      expect { venue.destroy! }.to change(VenueSlugRedirect, :count).by(-1)
      expect(Venue.find_by_public_slug("pop-up-hall")).to be_nil
    end

    it "rejects a link another venue used before" do
      venue = create(:venue, name: "Tumon Hall", slug: nil)
      venue.update!(slug: "tumon-grand-hall")
      other = create(:venue)

      expect(other.update(slug: "tumon-hall")).to be(false)
      expect(other.errors.full_messages).to include("Venue link is already used by another venue")
    end
  end
end
