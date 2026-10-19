# frozen_string_literal: true

# Case- and accent-insensitive text matching for search boxes, so "hafa" finds
# "Håfa" and "humatak" finds "Humåtak" (and the reverse). Accented letters are
# folded to lowercase ASCII with translate() before lower(), so the result never
# depends on the database's LC_CTYPE (production may run with a C locale). Input
# gets the same folding in Ruby and is quoted by Arel. Needs no extension or
# migration. Conditions are built with Arel from the model's own column names.
module AccentInsensitiveSearch
  extend ActiveSupport::Concern

  ACCENTED = "åàáâäãāéèêëēíìîïīóòôöõōúùûüūñÅÀÁÂÄÃĀÉÈÊËĒÍÌÎÏĪÓÒÔÖÕŌÚÙÛÜŪÑ"
  PLAIN = "aaaaaaaeeeeeiiiiioooooouuuuunaaaaaaaeeeeeiiiiioooooouuuuun"

  # SQL text of the fold, used to build matching expression indexes.
  def self.fold(sql)
    "lower(translate(#{sql}, '#{ACCENTED}', '#{PLAIN}'))"
  end

  # Ruby equivalent of fold, applied to user input before binding.
  def self.fold_value(value)
    value.to_s.strip.tr(ACCENTED, PLAIN).downcase
  end

  def self.contains_pattern(query)
    "%#{ActiveRecord::Base.sanitize_sql_like(fold_value(query))}%"
  end

  class_methods do
    # Rows where any of the named attributes contains the query, e.g.
    # Event.accent_insensitive_search(params[:q], :title, :venue_name).
    def accent_insensitive_search(query, *attributes)
      pattern = AccentInsensitiveSearch.contains_pattern(query)
      where(attributes.map { |attribute| accent_folded(attribute).matches(pattern, nil, true) }.reduce(:or))
    end

    # Rows where the named attribute equals the value, e.g. a village filter.
    def accent_insensitive_equals(attribute, value)
      where(accent_folded(attribute).eq(AccentInsensitiveSearch.fold_value(value)))
    end

    private

    # Arel form of AccentInsensitiveSearch.fold for one of this model's columns.
    # Only real column names are accepted, so callers cannot inject SQL.
    def accent_folded(attribute)
      name = attribute.to_s
      raise ArgumentError, "#{self.name} has no column #{name}" unless column_names.include?(name)

      translated = Arel::Nodes::NamedFunction.new("translate", [arel_table[name],
        Arel::Nodes.build_quoted(AccentInsensitiveSearch::ACCENTED), Arel::Nodes.build_quoted(AccentInsensitiveSearch::PLAIN)])
      Arel::Nodes::NamedFunction.new("lower", [translated])
    end
  end
end
