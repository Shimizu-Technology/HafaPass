# frozen_string_literal: true

namespace :translations do
  desc "Machine translate public events and ticket types without a current translation (safe to re-run)"
  task backfill: :environment do
    unless GtTranslationService.enabled?
      abort "Set HAFAPASS_MACHINE_TRANSLATION=true, GT_API_KEY and GT_PROJECT_ID first."
    end

    # Runs the job's work directly (not perform_now), so a General Translation
    # error is reported here instead of being swallowed into a queued retry.
    job = TranslateRecordJob.new
    failures = 0
    [Event, TicketType].each do |model|
      scope = model.where(translation_status: %w[untranslated failed unavailable])
      puts "#{model.name}: #{scope.count} to check"
      scope.find_each do |record|
        next unless record.machine_translation_eligible?

        job.perform(model.name, record.id, nil, false)
        status = record.reload.translation_status
        failures += 1 unless status == "translated"
        puts "  #{model.name}##{record.id} #{status}"
      rescue GtTranslationService::Unavailable => e
        abort "General Translation is unavailable (#{e.message}); nothing more was sent. Re-run later."
      rescue GtTranslationService::TranslationError => e
        failures += 1
        record.update_column(:translation_status, "failed")
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
