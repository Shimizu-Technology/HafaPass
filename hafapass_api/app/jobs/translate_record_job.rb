# frozen_string_literal: true

# Translates a record's changed organizer text and merges the results into its
# `translations`, one locale at a time. Safe to run twice: only locales missing
# a current translation are requested unless forced; a locale the service
# does not return keeps its existing translation; and a result is only stored
# if the English it was made from is still the saved text (a newer edit
# queues its own job).
class TranslateRecordJob < ApplicationJob
  queue_as :low

  TRANSLATABLE_CLASSES = %w[Event TicketType].freeze

  retry_on GtTranslationService::TranslationError, wait: :polynomially_longer, attempts: 4 do |job, error|
    job.settle("failed", error)
  end
  # Declared last so it wins over retry_on: no retries while out of credit.
  rescue_from(GtTranslationService::Unavailable) { |error| settle("unavailable", error) }

  def perform(class_name, record_id, fields = nil, force = false)
    record = find_record(class_name, record_id)
    return unless record
    return reset_pending(record) unless GtTranslationService.enabled? && record.machine_translation_eligible?

    names = fields ? record.translatable_field_names & Array(fields).map(&:to_s) : record.translatable_field_names
    sources = names.index_with { |field| record[field].to_s }
    results = request_translations(record, sources, force)

    store(record, sources, results)
  end

  # Final outcome after retries ran out (or the service is unavailable). A
  # translation another job already completed is never overwritten.
  def settle(status, error)
    record = find_record(arguments[0], arguments[1])
    Rails.logger.warn("[TranslateRecordJob] #{arguments[0]}##{arguments[1]} #{status}: #{error.message}")
    return unless record

    record.with_lock do
      next unless record.translation_status == "pending" && !record.translation_complete?

      record.update_column(:translation_status, status)
    end
  end

  private

  def find_record(class_name, record_id)
    return unless TRANSLATABLE_CLASSES.include?(class_name)

    class_name.constantize.find_by(id: record_id)
  end

  def reset_pending(record)
    record.update_column(:translation_status, "untranslated") if record.translation_status == "pending"
  end

  # { field => { locale => text } } for the locales each field still needs.
  def request_translations(record, sources, force)
    service = GtTranslationService.new
    AppLocale::TRANSLATION_TARGETS.each_with_object({}) do |locale, results|
      needed = sources.select do |field, text|
        text.present? && (force || !record.machine_translation_current?(field, text, locales: locale))
      end
      next if needed.empty?

      service.translate(needed, context: record.translation_context, locales: [locale]).each do |field, translated|
        (results[field] ||= {}).merge!(translated)
      end
    end
  end

  def store(record, sources, results)
    record.with_lock do
      merged = record.translations.is_a?(Hash) ? record.translations.deep_dup : {}
      superseded = false
      sources.each do |field, source|
        current = record[field].to_s
        if current.blank?
          merged.delete(field)
        elsif current != source
          superseded = true
        else
          digest = Translatable.digest(current)
          kept = merged[field].is_a?(Hash) && merged[field][Translatable::DIGEST_KEY] == digest ? merged[field] : {}
          merged[field] = kept.merge(results.fetch(field, {})).merge(Translatable::DIGEST_KEY => digest)
        end
      end

      done = sources.keys.all? do |field|
        record[field].blank? || record.machine_translation_current?(field, record[field], merged)
      end
      # Fields outside this job (still queued elsewhere) do not make it a failure.
      status = if record.translation_complete?(merged) then "translated"
      elsif superseded || done then record.translation_status
      else "failed"
      end
      record.update_columns(translations: merged, translation_status: status)
    end
  end
end
