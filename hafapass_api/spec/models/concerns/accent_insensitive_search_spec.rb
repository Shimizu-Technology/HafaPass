require "rails_helper"

RSpec.describe AccentInsensitiveSearch do
  let(:organizer_profile) { create(:organizer_profile) }
  let!(:hafa) { create(:event, organizer_profile: organizer_profile, title: "Håfa Adai Night", venue_city: "Tumon") }
  let!(:humatak) { create(:event, organizer_profile: organizer_profile, title: "Sunset Market", venue_city: "Humåtak") }

  it "matches accented text from plain input" do
    expect(Event.accent_insensitive_search("hafa", "events.title")).to contain_exactly(hafa)
    expect(Event.accent_insensitive_search("HUMATAK", "events.title", "events.venue_city")).to contain_exactly(humatak)
  end

  it "matches plain text from accented input" do
    plain = create(:event, organizer_profile: organizer_profile, title: "Hafa Pass Launch")

    expect(Event.accent_insensitive_search("Håfa", "events.title")).to contain_exactly(hafa, plain)
  end

  it "compares whole values for exact filters" do
    expect(Event.accent_insensitive_equals("events.venue_city", " humatak ")).to contain_exactly(humatak)
    expect(Event.accent_insensitive_equals("events.venue_city", "huma")).to be_empty
  end

  it "binds input and treats LIKE wildcards literally" do
    expect(Event.accent_insensitive_search("%", "events.title")).to be_empty
    expect(Event.accent_insensitive_search("'); DROP TABLE events; --", "events.title")).to be_empty
    expect(Event.count).to eq(2)
  end
end
