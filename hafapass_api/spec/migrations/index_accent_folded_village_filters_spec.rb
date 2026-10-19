require "rails_helper"
require Rails.root.join("db/migrate/20261020090000_index_accent_folded_village_filters")

RSpec.describe IndexAccentFoldedVillageFilters, :non_transactional do
  self.use_transactional_tests = false

  let(:migration) { described_class.new }
  let(:connection) { ActiveRecord::Base.connection }

  before do
    raise "Migration specs must only run in test" unless Rails.env.test?

    migration.down
  end

  after { migration.up }

  def index_named(table, name)
    connection.indexes(table).find { |entry| entry.name == name }
  end

  it "indexes exactly the folded expression the village filters query and retires LOWER(venue_city)" do
    migration.up

    described_class::INDEXES.each do |table, index|
      created = index_named(table, index[:name])
      expect(created).to be_valid
      expect(created.columns).to include("translate", index[:column], AccentInsensitiveSearch::ACCENTED,
        AccentInsensitiveSearch::PLAIN)
    end
    expect(index_named(:events, described_class::LEGACY_EVENTS_INDEX)).to be_nil

    migration.up
    expect(described_class::INDEXES.map { |table, index| index_named(table, index[:name]) }).to all(be_valid)
  end

  it "restores the legacy index on rollback" do
    migration.up
    migration.down

    expect(index_named(:events, described_class::LEGACY_EVENTS_INDEX)).to be_present
    described_class::INDEXES.each { |table, index| expect(index_named(table, index[:name])).to be_nil }
    expect { migration.down }.not_to raise_error
  end
end
