# frozen_string_literal: true

# docs/design/never-fulfilled-captures.md §4.5 and §10.5. Nothing schedules
# these. reconcile is a dry run unless DRY_RUN=0; an actual run on a shared or
# production database needs an authorized disposition (§10.5).
namespace :never_fulfilled do
  desc "Report (DRY_RUN=1, default) or write never-fulfilled backfill classifications and return postings"
  task reconcile: :environment do
    dry_run = ENV.fetch("DRY_RUN", "1") != "0"
    ids = ENV["PAYMENT_IDS"].to_s.split(",").map(&:strip).reject(&:empty?).presence
    report = Commerce::NeverFulfilledReconcile.call(dry_run: dry_run, payment_ids: ids)
    puts "never_fulfilled:reconcile #{dry_run ? 'DRY RUN (nothing written)' : 'WRITE'}"
    puts "dispositions: #{report.counts.sort.to_h}"
    puts "reasons: #{report.reasons.sort.to_h}"
    report.assessments.each do |item|
      puts [item.payment_id, item.order_id, item.disposition, item.reason, "movements=#{item.movement_count}"].compact.join("\t")
    end
  end

  desc "Read-only counts: unclassified late-capture payments and unposted movements on classified payments"
  task verify: :environment do
    report = Commerce::NeverFulfilledReconcile.call(dry_run: true)
    pending = report.assessments.reject { |item| %w[held reconciled].include?(item.disposition) }
    puts "unclassified_or_unposted=#{pending.count} dispositions=#{report.counts.sort.to_h}"
    puts "unposted_movement_payments=#{Commerce::NeverFulfilledReconcile.unposted_movement_payment_ids.count}"
  end
end
