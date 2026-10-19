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

  it "folds upper-case accented values without relying on database lower()" do
    shouting = create(:event, organizer_profile: organizer_profile, title: "HÅFA PASS LAUNCH", venue_city: "HUMÅTAK")

    expect(Event.accent_insensitive_search("hafa", "events.title")).to contain_exactly(hafa, shouting)
    expect(Event.accent_insensitive_search("HÅFA PASS", "events.title")).to contain_exactly(shouting)
    expect(Event.accent_insensitive_equals("events.venue_city", "Humatak")).to contain_exactly(humatak, shouting)
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

  describe "folding helpers" do
    it "keeps the accented and plain lists aligned one-to-one" do
      expect(described_class::ACCENTED.length).to eq(described_class::PLAIN.length)
      expect(described_class::PLAIN).to match(/\A[a-z]+\z/)
      expect(described_class::ACCENTED.chars.uniq.length).to eq(described_class::ACCENTED.length)
      expect(described_class::ACCENTED).to include("Å", "å", "Ñ", "ñ")
    end

    it "translates before lowercasing in SQL and binds input" do
      expect(described_class.fold("events.title"))
        .to eq("lower(translate(events.title, '#{described_class::ACCENTED}', '#{described_class::PLAIN}'))")
      expect(described_class.contains_any_sql("events.title", "events.venue_city"))
        .to eq("#{described_class.fold('events.title')} LIKE :search_pattern OR " \
          "#{described_class.fold('events.venue_city')} LIKE :search_pattern")
    end

    it "folds input the same way in Ruby" do
      expect(described_class.fold_value(" HÅFA Humåtak Señor ")).to eq("hafa humatak senor")
      expect(described_class.contains_pattern("Hå%fa_")).to eq("%ha\\%fa\\_%")
    end
  end
end
