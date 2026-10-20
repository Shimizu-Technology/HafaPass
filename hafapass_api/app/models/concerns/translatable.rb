# frozen_string_literal: true

require "digest"

# Organizer-written text (in English) is machine translated after it is saved.
# `translations` holds { field => { "_digest" => source digest, locale => text } };
# a translation only shows while its digest still matches the English text, so
# an edit never leaves an outdated translation on the page while the new one is
# being made. Without General Translation credentials nothing is queued and
# every locale reads the English text.
module Translatable
  extend ActiveSupport::Concern

  STATUSES = %w[untranslated pending translated failed].freeze
  DIGEST_KEY = "_digest"

  included do
    class_attribute :translatable_field_names, instance_writer: false, default: [].freeze
    class_attribute :translation_context, instance_writer: false

    validates :translation_status, inclusion: { in: STATUSES }
    before_save :track_translatable_changes
    after_commit :enqueue_translation, on: %i[create update], if: -> { @translatable_changes.present? }
  end

  class_methods do
    def translates(*fields, context:)
      self.translatable_field_names = fields.map(&:to_s).freeze
      self.translation_context = context
    end
  end

  def self.digest(text)
    Digest::SHA256.hexdigest(text.to_s)[0, 16]
  end

  # The machine translation of one field, or nil when there is none for the
  # current English text.
  def machine_translation(field, locale)
    entry = translations.is_a?(Hash) ? translations[field.to_s] : nil
    source = self[field.to_s]
    return nil unless entry.is_a?(Hash) && source.present? && entry[DIGEST_KEY] == Translatable.digest(source)

    entry[locale.to_s].presence
  end

  # [text, machine_translated?] for a field in a supported locale.
  def translated_value(field, locale)
    english = self[field.to_s]
    return [english, false] if locale.to_s == AppLocale::DEFAULT

    translated = machine_translation(field, locale)
    translated ? [translated, true] : [english, false]
  end

  # True when the field has a translation in every target locale for this English text.
  def machine_translation_current?(field, source = self[field.to_s], snapshot = translations)
    entry = snapshot.is_a?(Hash) ? snapshot[field.to_s] : nil
    entry.is_a?(Hash) && entry[DIGEST_KEY] == Translatable.digest(source) &&
      AppLocale::TRANSLATION_TARGETS.all? { |locale| entry[locale].present? }
  end

  def translation_complete?(snapshot = translations)
    translatable_field_names.all? do |field|
      self[field].blank? || machine_translation_current?(field, self[field], snapshot)
    end
  end

  # Re-translates every field, replacing existing machine translations.
  def retranslate!
    return false unless GtTranslationService.configured?

    update_column(:translation_status, "pending")
    TranslateRecordJob.perform_later(self.class.name, id, nil, true)
    true
  end

  private

  def track_translatable_changes
    changed = translatable_field_names.select { |field| will_save_change_to_attribute?(field) }
    @translatable_changes = Array(@translatable_changes) | changed
  end

  def enqueue_translation
    fields = @translatable_changes
    @translatable_changes = nil
    return unless GtTranslationService.configured?

    update_column(:translation_status, "pending")
    TranslateRecordJob.perform_later(self.class.name, id, fields, false)
  end
end
