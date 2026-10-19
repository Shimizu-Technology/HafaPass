# frozen_string_literal: true

# Case- and accent-insensitive text matching for search boxes, so "hafa" finds
# "Håfa" and "humatak" finds "Humåtak" (and the reverse). Both the column and the
# bound input are lowercased and folded with Postgres translate(), which needs no
# extension or migration. Column names must be trusted SQL; user input is always bound.
module AccentInsensitiveSearch
  extend ActiveSupport::Concern

  ACCENTED = "åàáâäãāéèêëēíìîïīóòôöõōúùûüūñ"
  PLAIN = "aaaaaaaeeeeeiiiiioooooouuuuun"

  def self.fold(sql)
    "translate(lower(#{sql}), '#{ACCENTED}', '#{PLAIN}')"
  end

  # SQL that is true when any column contains the :search_pattern bind.
  def self.contains_any_sql(*columns)
    columns.map { |column| "#{fold(column)} LIKE #{fold(':search_pattern')}" }.join(" OR ")
  end

  # SQL that is true when the column equals the :search_value bind.
  def self.equals_sql(column)
    "#{fold(column)} = #{fold(':search_value')}"
  end

  def self.contains_pattern(query)
    "%#{ActiveRecord::Base.sanitize_sql_like(query.to_s.strip)}%"
  end

  class_methods do
    def accent_insensitive_search(query, *columns)
      where(AccentInsensitiveSearch.contains_any_sql(*columns), search_pattern: AccentInsensitiveSearch.contains_pattern(query))
    end

    def accent_insensitive_equals(column, value)
      where(AccentInsensitiveSearch.equals_sql(column), search_value: value.to_s.strip)
    end
  end
end
