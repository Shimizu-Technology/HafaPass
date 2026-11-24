# frozen_string_literal: true

# One shared counter per public cache. Every Puma worker keeps its own
# MemoryStore, so a sell-out (or inventory coming back) bumps this row after
# commit and every worker's next public event read misses its old entries.
class CreatePublicCacheGenerations < ActiveRecord::Migration[8.1]
  def change
    create_table :public_cache_generations do |t|
      t.string :name, null: false
      t.bigint :value, null: false, default: 0
      t.timestamps
    end
    add_index :public_cache_generations, :name, unique: true
  end
end
