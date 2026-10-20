# frozen_string_literal: true

# Loads buyer email copy from config/email_locales/<locale>.yml (evaluated by
# I18n as part of config.i18n.load_path, so it reloads like any locale file).
#
# Those files have no locale root key: the `gt` CLI translates the values of
# en.yml into the other files without touching keys, and the file name says
# which language it is. A translated string is ignored, so English is used
# instead, when it does not keep exactly the English %{placeholders}, or a
# list does not keep the English length.
require "yaml"

directory = File.expand_path("../email_locales", File.dirname(__FILE__))
placeholders = ->(text) { text.scan(/%\{(\w+)\}/).flatten.sort }
compatible = lambda do |english, translated, recurse|
  case english
  when Hash
    next {} unless translated.is_a?(Hash)

    english.each_with_object({}) do |(key, value), kept|
      result = recurse.call(value, translated[key], recurse)
      kept[key] = result unless result.nil? || result == {}
    end
  when Array
    translated if translated.is_a?(Array) && translated.length == english.length && translated.all?(String)
  when String
    translated if translated.is_a?(String) && translated.strip != "" && placeholders.call(translated) == placeholders.call(english)
  end
end

english = YAML.safe_load_file(File.join(directory, "en.yml"))
Dir[File.join(directory, "*.yml")].sort.each_with_object({ en: english }) do |path, all|
  locale = File.basename(path, ".yml")
  next if locale == "en" || locale.include?(".") # en.metadata.yml holds translator context only

  all[locale.to_sym] = compatible.call(english, YAML.safe_load_file(path) || {}, compatible)
end
