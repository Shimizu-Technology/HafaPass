# frozen_string_literal: true

# R2-2 history (docs/design/never-fulfilled-captures.md §8.6, §8.10.5,
# §8.10.11). Nothing schedules these. `derive` is a dry run unless DRY_RUN=0,
# and a write needs AUTHORIZED_BY (the person or ticket that authorized it,
# kept in each row's evidence); the database refuses a historical row without
# it. A write on a shared or production database is part of the authorized
# A2 release (home base), and only adds rows for payouts recorded paid before
# the A2 payout entry cutover that have none; it never changes an existing
# one. `verify` is read-only release evidence.
namespace :payout_custody do
  desc "Report (DRY_RUN=1, default) or write (DRY_RUN=0 AUTHORIZED_BY=...) historical custody determinations"
  task derive: :environment do
    dry_run = ENV.fetch("DRY_RUN", "1") != "0"
    ids = ENV["PAYOUT_IDS"].to_s.split(",").map(&:strip).reject(&:empty?).presence
    rows = PayoutCustody.derive_history!(dry_run: dry_run, payout_ids: ids, authorized_by: ENV["AUTHORIZED_BY"])
    puts "payout_custody:derive #{dry_run ? 'DRY RUN (nothing written)' : "WRITE authorized by #{ENV['AUTHORIZED_BY']}"}"
    written = rows.reject { |row| row[:skipped] }
    puts "determinations: #{written.group_by { |row| row[:determination] }.transform_values(&:size).sort.to_h}"
    puts "skipped: #{rows.count { |row| row[:skipped] }}"
    rows.each { |row| puts row.values_at(:payout_id, :determination, :conservative_inclusion, :skipped).compact.join("\t") }
  rescue ArgumentError => e
    abort "payout_custody:derive refused: #{e.message}"
  end

  desc "Read-only: paid or reversed payouts with no custody determination, and ambiguous ones"
  task verify: :environment do
    scope = Payout.where(status: %i[paid reversed]).where.not(paid_at: nil)
    undetermined = PayoutCustody.undetermined(scope).order(:id).pluck(:id)
    ambiguous = PayoutCustodyDetermination.where(determination: "ambiguous").order(:payout_id).pluck(:payout_id)
    cutover = FinancialCutover.recorded_at(FinancialIntegrity::PAYOUT_ENTRY_CUTOVER)
    puts "payout_entry_cutover=#{cutover&.utc&.iso8601(6) || 'missing'}"
    puts "undetermined_paid_payouts=#{undetermined.size}#{" ids=#{undetermined.join(',')}" if undetermined.any?}"
    puts "ambiguous_determinations=#{ambiguous.size}#{" payout_ids=#{ambiguous.join(',')}" if ambiguous.any?}"
    puts "determinations_by_basis=#{PayoutCustodyDetermination.group(:basis, :determination).count.sort.to_h}"
  end
end
