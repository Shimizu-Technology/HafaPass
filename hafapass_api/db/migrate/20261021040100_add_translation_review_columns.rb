# frozen_string_literal: true

# Retranslation requests are rate limited per event, and organizer wording
# remembers which English it was written for so stale wording can be flagged.
class AddTranslationReviewColumns < ActiveRecord::Migration[8.1]
  def change
    reversible { |direction| direction.up { execute "SET LOCAL lock_timeout = '5s'" } }
    add_column :events, :translation_requested_at, :datetime
    add_column :events, :localized_content_sources, :jsonb, default: {}, null: false
  end
end
