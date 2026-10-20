# frozen_string_literal: true

# Translates a record's changed organizer text into every target locale and
# merges the results into its `translations`. Safe to run twice: fields whose
# English already has a current translation are skipped unless forced, and a
# result is only stored if the English it was made from is still the saved
# text (a newer edit queues its own job).
class TranslateRecordJob < ApplicationJob
  queue_as :low

  TRANSLATABLE_CLASSES = %w[Event TicketType].freeze

  retry_on GtTranslationService::TranslationError, wait: :polynomially_longer, attempts: 4 do |job, error|
    job.mark_failed(error)
  end

  def perform(class_name, record_id, fields = nil, force = false)
    record = find_record(class_name, record_id)
    return unless record
    return reset_pending(record) unless GtTranslationService.configured?

    names = fields ? record.translatable_field_names & Array(fields).map(&:to_s) : record.translatable_field_names
    sources = names.index_with { |field| record[field].to_s }
    requested = sources.reject do |field, text|
      text.blank? || (!force && record.machine_translation_current?(field, text))
    end
    results = GtTranslationService.new.translate(requested, context: record.translation_context)

    store(record, sources, requested, results)
  end

  def mark_failed(error)
    record = find_record(arguments[0], arguments[1])
    Rails.logger.error("[TranslateRecordJob] #{arguments[0]}##{arguments[1]} failed: #{error.message}")
    record&.update_column(:translation_status, "failed")
  end

  private

  def find_record(class_name, record_id)
    return unless TRANSLATABLE_CLASSES.include?(class_name)

    class_name.constantize.find_by(id: record_id)
  end

  def reset_pending(record)
    record.update_column(:translation_status, "untranslated") if record.translation_status == "pending"
  end

  def store(record, sources, requested, results)
    record.with_lock do
      merged = record.translations.is_a?(Hash) ? record.translations.deep_dup : {}
      superseded = false
      sources.each_key do |field|
        current = record[field].to_s
        if current.blank?
          merged.delete(field)
        elsif current != sources[field]
          superseded = true
        elsif requested.key?(field)
          merged[field] = results.fetch(field, {}).merge(Translatable::DIGEST_KEY => Translatable.digest(current))
        end
      end

      status = if record.translation_complete?(merged) then "translated"
      elsif superseded then record.translation_status
      else "failed"
      end
      record.update_columns(translations: merged, translation_status: status)
    end
  end
end
