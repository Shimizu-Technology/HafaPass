# Village filters compare AccentInsensitiveSearch.fold(column) for equality, which
# the old LOWER(venue_city) index cannot serve. Build the indexes from the concern's
# own fold so the indexed expression and the query expression stay identical.
class IndexAccentFoldedVillageFilters < ActiveRecord::Migration[8.1]
  disable_ddl_transaction!

  INDEXES = {
    events: { name: "index_events_on_folded_venue_city", column: "venue_city" },
    venues: { name: "index_venues_on_folded_village", column: "village" }
  }.freeze
  LEGACY_EVENTS_INDEX = "index_events_on_lower_venue_city"

  def up
    INDEXES.each do |table, index|
      existing = connection.indexes(table).find { |entry| entry.name == index[:name] }
      next if existing&.valid?

      remove_index table, name: index[:name], algorithm: :concurrently if existing
      add_index table, AccentInsensitiveSearch.fold(index[:column]), name: index[:name], algorithm: :concurrently
    end
    # Nothing else queries LOWER(venue_city) once the village filter is folded.
    remove_index :events, name: LEGACY_EVENTS_INDEX, algorithm: :concurrently, if_exists: true
  end

  def down
    unless connection.index_name_exists?(:events, LEGACY_EVENTS_INDEX)
      add_index :events, "LOWER(venue_city)", name: LEGACY_EVENTS_INDEX, algorithm: :concurrently
    end
    INDEXES.each do |table, index|
      remove_index table, name: index[:name], algorithm: :concurrently, if_exists: true
    end
  end
end
