namespace :events do
  desc "Mark published events with starts_at > 6 hours ago as completed"
  task complete_past: :environment do
    cutoff = 6.hours.ago
    events = Event.published.where("starts_at < ?", cutoff)
    count = events.count
    events.update_all(status: Event.statuses[:completed])
    puts "Marked #{count} past events as completed."
  end
end
