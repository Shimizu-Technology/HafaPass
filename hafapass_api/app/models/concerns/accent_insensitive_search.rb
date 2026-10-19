# frozen_string_literal: true

# Case- and accent-insensitive text matching for search boxes, so "hafa" finds
# "Håfa" and "humatak" finds "Humåtak" (and the reverse). Accented letters are
# folded to lowercase ASCII with translate() before lower(), so the result never
# depends on the database's LC_CTYPE (production may run with a C locale). Input
# gets the same folding in Ruby and is always bound. Needs no extension or
# migration. Column names must be trusted SQL.
module AccentInsensitiveSearch
  extend ActiveSupport::Concern

  ACCENTED = "åàáâäãāéèêëēíìîïīóòôöõōúùûüūñÅÀÁÂÄÃĀÉÈÊËĒÍÌÎÏĪÓÒÔÖÕŌÚÙÛÜŪÑ"
  PLAIN = "aaaaaaaeeeeeiiiiioooooouuuuunaaaaaaaeeeeeiiiiioooooouuuuun"

  def self.fold(sql)
    "lower(translate(#{sql}, '#{ACCENTED}', '#{PLAIN}'))"
  end

  # Ruby equivalent of fold, applied to user input before binding.
  def self.fold_value(value)
    value.to_s.strip.tr(ACCENTED, PLAIN).downcase
  end

  # SQL that is true when any column contains the :search_pattern bind.
  def self.contains_any_sql(*columns)
    columns.map { |column| "#{fold(column)} LIKE :search_pattern" }.join(" OR ")
  end

  # SQL that is true when the column equals the :search_value bind.
  def self.equals_sql(column)
    "#{fold(column)} = :search_value"
  end

  def self.contains_pattern(query)
    "%#{ActiveRecord::Base.sanitize_sql_like(fold_value(query))}%"
  end

  class_methods do
    def accent_insensitive_search(query, *columns)
      where(AccentInsensitiveSearch.contains_any_sql(*columns), search_pattern: AccentInsensitiveSearch.contains_pattern(query))
    end

    def accent_insensitive_equals(column, value)
      where(AccentInsensitiveSearch.equals_sql(column), search_value: AccentInsensitiveSearch.fold_value(value))
    end
  end
end
