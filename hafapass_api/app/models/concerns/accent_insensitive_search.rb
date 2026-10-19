# frozen_string_literal: true

# Case- and accent-insensitive text matching for search boxes, so "hafa" finds
# "Håfa" and "humatak" finds "Humåtak" (and the reverse). Accented letters are
# folded to lowercase ASCII with translate() before lower(), so listed accents
# never depend on the database's LC_CTYPE (production may run with a C locale).
# The column and the bound user input go through the identical SQL expression,
# so any other character is treated the same way on both sides. Needs no
# extension or migration. Conditions are built with Arel from the model's own
# column names, and input is always a bind parameter.
module AccentInsensitiveSearch
  extend ActiveSupport::Concern

  ACCENTED = "åàáâäãāéèêëēíìîïīóòôöõōúùûüūñÅÀÁÂÄÃĀÉÈÊËĒÍÌÎÏĪÓÒÔÖÕŌÚÙÛÜŪÑ"
  PLAIN = "aaaaaaaeeeeeiiiiioooooouuuuunaaaaaaaeeeeeiiiiioooooouuuuun"

  # SQL text of the fold, used to build matching expression indexes.
  def self.fold(sql)
    "lower(translate(#{sql}, '#{ACCENTED}', '#{PLAIN}'))"
  end

  # Arel form of fold for any expression node.
  def self.fold_node(node)
    translated = Arel::Nodes::NamedFunction.new("translate",
      [node, Arel::Nodes.build_quoted(ACCENTED), Arel::Nodes.build_quoted(PLAIN)])
    Arel::Nodes::NamedFunction.new("lower", [translated])
  end

  def self.bind(name, value)
    Arel::Nodes::BindParam.new(
      ActiveRecord::Relation::QueryAttribute.new(name, value, ActiveRecord::Type::String.new)
    )
  end

  def self.contains_pattern(query)
    "%#{ActiveRecord::Base.sanitize_sql_like(query.to_s.strip)}%"
  end

  class_methods do
    # Rows where any of the named attributes contains the query, e.g.
    # Event.accent_insensitive_search(params[:q], :title, :venue_name).
    def accent_insensitive_search(query, *attributes)
      pattern = AccentInsensitiveSearch.fold_node(
        AccentInsensitiveSearch.bind("search_pattern", AccentInsensitiveSearch.contains_pattern(query))
      )
      where(attributes.map { |attribute| accent_folded(attribute).matches(pattern, nil, true) }.reduce(:or))
    end

    # Rows where the named attribute equals the value, e.g. a village filter.
    def accent_insensitive_equals(attribute, value)
      folded_value = AccentInsensitiveSearch.fold_node(AccentInsensitiveSearch.bind("search_value", value.to_s.strip))
      where(accent_folded(attribute).eq(folded_value))
    end

    private

    # Folded expression for one of this model's columns. Only real column
    # names are accepted, so callers cannot inject SQL.
    def accent_folded(attribute)
      name = attribute.to_s
      raise ArgumentError, "#{self.name} has no column #{name}" unless column_names.include?(name)

      AccentInsensitiveSearch.fold_node(arel_table[name])
    end
  end
end
