namespace :events do
  desc "Mark published events completed 6 hours after they end (same as the hourly CompletePastEventsJob)"
  task complete_past: :environment do
    count = CompletePastEventsJob.perform_now
    puts "Marked #{count} past events as completed."
  end
end
