# frozen_string_literal: true

require "digest"

# Organizer-written text (in English) is machine translated after it is saved.
# `translations` holds { field => { "_digest" => source digest, locale => text } };
# a translation only shows while its digest still matches the English text, so
# an edit never leaves an outdated translation on the page while the new one is
# being made.
#
# Nothing is queued or served unless HAFAPASS_MACHINE_TRANSLATION is on and
# General Translation credentials are set (GtTranslationService.enabled?), and
# only public records are sent: a model decides that with
# `machine_translation_eligible?` (drafts and hidden events never leave HåfaPass).
module Translatable
  extend ActiveSupport::Concern

  # "unavailable": General Translation is out of credit or rate limited;
  # buyers see English and the organizer is not told something broke.
  STATUSES = %w[untranslated pending translated failed unavailable].freeze
  DIGEST_KEY = "_digest"
  RETRANSLATE_COOLDOWN = 5.minutes
  STUCK_PENDING_AFTER = 30.minutes

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

  def machine_translation_eligible?
    true
  end

  # The machine translation of one field, or nil when machine translation is
  # off or there is none for the current English text.
  def machine_translation(field, locale)
    return nil unless AppLocale.machine_translation_enabled?

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

  # True when the field has a current translation in `locale` (or every target).
  def machine_translation_current?(field, source = self[field.to_s], snapshot = translations, locales: AppLocale.enabled - [AppLocale::DEFAULT])
    entry = snapshot.is_a?(Hash) ? snapshot[field.to_s] : nil
    entry.is_a?(Hash) && entry[DIGEST_KEY] == Translatable.digest(source) &&
      Array(locales).all? { |locale| entry[locale].present? }
  end

  def translation_complete?(snapshot = translations)
    translatable_field_names.all? do |field|
      self[field].blank? || machine_translation_current?(field, self[field], snapshot)
    end
  end

  # Re-translates every field from scratch (existing good translations are
  # kept for any locale the service does not return). Returns :queued, or why
  # not: :unavailable (off or no credentials), :not_public, :recently_requested.
  def retranslate!
    return :unavailable unless GtTranslationService.enabled?
    return :not_public unless machine_translation_eligible?
    return :recently_requested if retranslation_too_soon?

    queue_translation!(nil, force: true)
    :queued
  end

  def queue_translation!(fields, force: false)
    columns = { translation_status: "pending" }
    columns[:translation_requested_at] = Time.current
    update_columns(columns)
    TranslateRecordJob.perform_later(self.class.name, id, fields, force)
  end

  private

  def retranslation_too_soon?
    return false unless has_attribute?(:translation_requested_at) && translation_requested_at

    translation_requested_at > RETRANSLATE_COOLDOWN.ago ||
      (translation_status == "pending" && translation_requested_at > STUCK_PENDING_AFTER.ago)
  end

  # Records whose text becomes public (an event being published) translate
  # every field, since nothing was sent while they were private.
  def translation_became_eligible?
    false
  end

  def track_translatable_changes
    @translation_became_eligible ||= translation_became_eligible?
    changed = translatable_field_names.select { |field| will_save_change_to_attribute?(field) }
    changed = translatable_field_names if @translation_became_eligible
    @translatable_changes = Array(@translatable_changes) | changed
  end

  def enqueue_translation
    fields = @translatable_changes
    became_eligible = @translation_became_eligible
    @translatable_changes = nil
    @translation_became_eligible = nil
    return unless GtTranslationService.enabled? && machine_translation_eligible?

    queue_translation!(fields)
    translation_cascade if became_eligible
  end

  def translation_cascade; end
end
