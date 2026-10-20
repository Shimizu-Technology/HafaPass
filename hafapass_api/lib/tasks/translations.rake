# frozen_string_literal: true

namespace :translations do
  desc "Machine translate events and ticket types that have no current translation (safe to re-run)"
  task backfill: :environment do
    abort "Set GT_API_KEY and GT_PROJECT_ID first." unless GtTranslationService.configured?

    failures = 0
    [Event, TicketType].each do |model|
      scope = model.where(translation_status: %w[untranslated failed])
      puts "#{model.name}: #{scope.count} to translate"
      scope.find_each do |record|
        TranslateRecordJob.perform_now(model.name, record.id, nil, false)
        status = record.reload.translation_status
        failures += 1 unless status == "translated"
        puts "  #{model.name}##{record.id} #{status}"
      rescue GtTranslationService::TranslationError => e
        failures += 1
        puts "  #{model.name}##{record.id} failed: #{e.message}"
      end
    end
    abort "#{failures} record(s) were not fully translated; re-run to retry them." if failures.positive?
    puts "Done."
  end

  desc "Count events and ticket types by translation status"
  task status: :environment do
    [Event, TicketType].each do |model|
      counts = model.group(:translation_status).count
      puts "#{model.name}: #{counts.sort.map { |status, count| "#{status} #{count}" }.join(', ')}"
    end
  end
end
