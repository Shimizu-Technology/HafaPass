require "rails_helper"

RSpec.describe AccentInsensitiveSearch do
  let(:organizer_profile) { create(:organizer_profile) }
  let!(:hafa) { create(:event, organizer_profile: organizer_profile, title: "Håfa Adai Night", venue_city: "Tumon") }
  let!(:humatak) { create(:event, organizer_profile: organizer_profile, title: "Sunset Market", venue_city: "Humåtak") }

  it "matches accented text from plain input" do
    expect(Event.accent_insensitive_search("hafa", :title)).to contain_exactly(hafa)
    expect(Event.accent_insensitive_search("HUMATAK", :title, :venue_city)).to contain_exactly(humatak)
  end

  it "matches plain text from accented input" do
    plain = create(:event, organizer_profile: organizer_profile, title: "Hafa Pass Launch")

    expect(Event.accent_insensitive_search("Håfa", :title)).to contain_exactly(hafa, plain)
  end

  it "folds upper-case accented values without relying on database lower()" do
    shouting = create(:event, organizer_profile: organizer_profile, title: "HÅFA PASS LAUNCH", venue_city: "HUMÅTAK")

    expect(Event.accent_insensitive_search("hafa", :title)).to contain_exactly(hafa, shouting)
    expect(Event.accent_insensitive_search("HÅFA PASS", :title)).to contain_exactly(shouting)
    expect(Event.accent_insensitive_equals(:venue_city, "Humatak")).to contain_exactly(humatak, shouting)
  end

  it "compares whole values for exact filters" do
    expect(Event.accent_insensitive_equals(:venue_city, " humatak ")).to contain_exactly(humatak)
    expect(Event.accent_insensitive_equals(:venue_city, "huma")).to be_empty
  end

  it "binds input and treats LIKE wildcards literally" do
    expect(Event.accent_insensitive_search("%", :title)).to be_empty
    expect(Event.accent_insensitive_search("'); DROP TABLE events; --", :title)).to be_empty
    expect(Event.count).to eq(2)
  end

  describe "folding helpers" do
    it "keeps the accented and plain lists aligned one-to-one" do
      expect(described_class::ACCENTED.length).to eq(described_class::PLAIN.length)
      expect(described_class::PLAIN).to match(/\A[a-z]+\z/)
      expect(described_class::ACCENTED.chars.uniq.length).to eq(described_class::ACCENTED.length)
      expect(described_class::ACCENTED).to include("Å", "å", "Ñ", "ñ")
    end

    it "translates before lowercasing in SQL and quotes input" do
      fold = described_class.fold("venue_city")
      expect(fold).to eq("lower(translate(venue_city, '#{described_class::ACCENTED}', '#{described_class::PLAIN}'))")
      sql = Event.accent_insensitive_search("Hå'fa", :title, :venue_city).to_sql
      expect(sql).to include(described_class.fold('"events"."title"') + " LIKE '%ha''fa%'")
      expect(sql).to include(described_class.fold('"events"."venue_city"') + " LIKE '%ha''fa%'")
      expect(Event.accent_insensitive_equals(:venue_city, "HUMÅTAK").to_sql)
        .to include(described_class.fold('"events"."venue_city"') + " = 'humatak'")
    end

    it "rejects anything that is not one of the model's columns" do
      expect { Event.accent_insensitive_search("x", "title) OR (1=1") }.to raise_error(ArgumentError)
      expect { Event.accent_insensitive_equals(:no_such_column, "x") }.to raise_error(ArgumentError)
    end

    it "folds input the same way in Ruby" do
      expect(described_class.fold_value(" HÅFA Humåtak Señor ")).to eq("hafa humatak senor")
      expect(described_class.contains_pattern("Hå%fa_")).to eq("%ha\\%fa\\_%")
    end
  end
end
