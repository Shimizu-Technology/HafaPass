# frozen_string_literal: true

# Machine translations of organizer-entered event content are stored beside
# the English source (one JSONB blob per record, keyed by field then locale)
# with a status the organizer UI can show. Orders, waitlist entries and ticket
# transfers remember the language the buyer was using so their emails can be
# written in it. Existing rows default to English, which is what they were
# sent in, so nothing already delivered changes.
class AddTranslationsAndLocales < ActiveRecord::Migration[8.1]
  def change
    %i[events ticket_types].each do |table|
      add_column table, :translations, :jsonb, default: {}, null: false
      add_column table, :translation_status, :string, default: "untranslated", null: false
    end

    %i[orders waitlist_entries ticket_transfers].each do |table|
      add_column table, :locale, :string, default: "en", null: false
    end
  end
end
