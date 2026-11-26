# frozen_string_literal: true

# R2-2 history (docs/design/never-fulfilled-captures.md §8.6, §8.10.5). Nothing
# schedules this. It is a dry run unless DRY_RUN=0. A write on a shared or
# production database is part of the authorized A2 release (home base), and
# only adds rows for payouts that have none; it never changes an existing one.
namespace :payout_custody do
  desc "Report (DRY_RUN=1, default) or write one derived_history custody determination per undetermined paid payout"
  task derive: :environment do
    dry_run = ENV.fetch("DRY_RUN", "1") != "0"
    ids = ENV["PAYOUT_IDS"].to_s.split(",").map(&:strip).reject(&:empty?).presence
    rows = PayoutCustody.derive_history!(dry_run: dry_run, payout_ids: ids)
    puts "payout_custody:derive #{dry_run ? 'DRY RUN (nothing written)' : 'WRITE'}"
    puts "determinations: #{rows.group_by { |row| row[:determination] }.transform_values(&:size).sort.to_h}"
    rows.each { |row| puts row.values_at(:payout_id, :determination, :conservative_inclusion).join("\t") }
  end
end
